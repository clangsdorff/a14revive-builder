#!/usr/bin/env bash
# Full CI build: download A166B + A145F, patch, rebuild system/product/vendor,
# pack the TWRP zip. Runs as root so uid/gid and xattrs survive extraction.
#
# env: PATCHSET SOURCE_MODEL SOURCE_CSC SOURCE_TAC TARGET_MODEL TARGET_CSC TARGET_TAC
#      SIGN_KEY SIGN_CERT KERNEL_TAG KERNEL_VARIANT ROM_VERSION WORK
set -euo pipefail

CI="$(cd "$(dirname "$0")" && pwd)"
W="${WORK:?}"
T="$W/tree"
cd "${PATCHSET:?}"

for f in update-binary unsparse_super_empty.img; do
    [ -f "$CI/prebuilt/$f" ] || { echo "prebuilt/$f missing"; exit 1; }
done

BT="$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)"
export PATH="$BT:$PATH"

latest() {
    curl -sf --retry 3 -A "samsung $1 SyncML DM Client" \
        "https://fota-cloud-dn.ospserver.net/firmware/$2/$1/version.xml" \
        | perl -nE 'say $1 if /<latest[^>]*>(.*?)<\/latest>/'
}

# download <model> <csc> <imei> <dir>: firmware zip into <dir>, sets FW
download() {
    FW="$(latest "$1" "$2")"
    [ -n "$FW" ] || { echo "no firmware for $1/$2"; exit 1; }
    echo "[*] $1/$2: $FW"
    mkdir -p "$4"
    (cd "$4" && samloader -m "$1" -r "$2" -i "$3" download -v "$FW" -O .)
}

# super <fw dir> <out dir> <part>...: super.img out of AP, unpacked to <out dir>
super() {
    local fw="$1" out="$2"; shift 2
    unzip -p "$fw"/*.zip 'AP_*.tar.md5' | tar -xO super.img.lz4 | lz4 -d > "$W/super.sparse"
    simg2img "$W/super.sparse" "$W/super.raw"
    rm "$W/super.sparse"
    local args=()
    for p in "$@"; do args+=(-p "$p"); done
    python3 "$CI/lpunpack.py" "$W/super.raw" "$out" "${args[@]}"
    rm "$W/super.raw"
}

extract() {
    rm -rf "$2"; mkdir -p "$2"
    fsck.erofs --extract="$2" --xattrs --preserve --overwrite "$1"
}

is_erofs() {
    [ "$(od -An -tx1 -j1024 -N4 "$1" | tr -d ' \n')" = "e2e1f5e0" ]
}

pack() {
    local uuid
    uuid="$(dump.erofs "$3" | awk '/UUID/ {print $NF}')"
    rm -f "$W/img/$1.img"
    mkfs.erofs -zlz4hc,level=12 -T1199145600 -b4096 -U "$uuid" -L"$1" \
        -E^xattr-name-filter --quiet "$W/img/$1.img" "$2"
}

mkdir -p "$W"/{src,tgt,parts,a145f,img,extra}

echo "::group::download"
download "$SOURCE_MODEL" "$SOURCE_CSC" "$SOURCE_TAC" "$W/src"; SRC_FW="$FW"
download "$TARGET_MODEL" "$TARGET_CSC" "$TARGET_TAC" "$W/tgt"; TGT_FW="$FW"
SRC_PDA="${SRC_FW%%/*}"; TGT_PDA="${TGT_FW%%/*}"
echo "::endgroup::"

echo "::group::unpack"
super "$W/src" "$W/parts" system product
rm -rf "$W/src"
super "$W/tgt" "$W/a145f" system vendor odm vendor_dlkm system_dlkm
unzip -p "$W"/tgt/*.zip 'BL_*.tar.md5' | tar -xO up_param.bin.lz4 | lz4 -d > "$W/extra/up_param.bin"
rm -rf "$W/tgt"
extract "$W/parts/system.img" "$T/system"
extract "$W/parts/product.img" "$T/product"
extract "$W/a145f/system.img" "$W/a145f/system"
rm "$W/a145f/system.img"
echo "::endgroup::"

echo "::group::kernel"
gh release download "$KERNEL_TAG" -R clangsdorff/langsdorffkernel \
    -p "langsdorff@${KERNEL_TAG}${KERNEL_VARIANT}_a14.tar" -O "$W/kernel.tar"
for f in boot vendor_boot vbmeta; do
    tar -xOf "$W/kernel.tar" "$f.img.lz4" | lz4 -d > "$W/extra/$f.img"
done
cp "$CI/prebuilt/update-binary" "$CI/prebuilt/unsparse_super_empty.img" "$W/extra/"
echo "::endgroup::"

echo "::group::patch apps"
rm -rf apks dist unpacked apktool_frameworks
mkdir -p apks "$W/apps"
[ -f apktool.jar ] || curl -sSfL -o apktool.jar \
    https://github.com/iBotPeaches/Apktool/releases/download/v3.0.2/apktool_3.0.2.jar
cp "$T/system/system/framework/framework-res.apk" apks/
targets=()
for p in patches/*_out.patch; do
    b="$(basename "$p" _out.patch)"
    hit="$(find "$T/system/system" "$T/product" -type f \( -name "$b.jar" -o -name "$b.apk" \) \
        -not -path '*/oat/*' | head -n 1)"
    [ -n "$hit" ] || { echo "$b: not found in $SOURCE_MODEL"; exit 1; }
    cp "$hit" apks/
    targets+=("$(basename "$hit")")
done
java -jar apktool.jar if apks/framework-res.apk -p apktool_frameworks
for t in "${targets[@]}"; do
    ./apply_patches.sh "$t" "${t%.*}_out.patch"
    cp "dist/${t%.*}_patched.${t##*.}" "$W/apps/$t"
done
echo "::endgroup::"

echo "::group::bluetooth apex"
apex="$(find "$T/system/system/apex" -name 'com.android.bt*.apex' | head -n 1)"
python3 port/bt_apex.py "$apex" tools/avb/avbtool.py tools/avb/testkey_rsa4096.pem "$W/bt.unsigned.apex"
zipalign -f 4096 "$W/bt.unsigned.apex" "$W/bt.aligned.apex"
apksigner sign --key "$SIGN_KEY" --cert "$SIGN_CERT" \
    --alignment-preserved --align-file-size --v1-signing-enabled true --v2-signing-enabled true \
    --v3-signing-enabled false --v4-signing-enabled false \
    --out "$W/apps/$(basename "$apex")" "$W/bt.aligned.apex"
echo "::endgroup::"

echo "::group::system"
bash port/debloat.sh "$T"
python3 port/install_apks.py "$T" "$W/apps"
python3 port/from_target.py port/from_target.txt "$W/a145f" "$T"
for part in system product; do
    [ -d "port/files/$part" ] || continue
    (cd "port/files/$part" && find . -type f ! -name .DS_Store) | while IFS= read -r f; do
        mkdir -p "$(dirname "$T/$part/$f")"
        python3 -c 'import sys; sys.path.insert(0, "port"); import from_target as f; f.put(*sys.argv[1:])' \
            "port/files/$part/$f" "$T/$part/$f"
    done
done
while read -r file lib; do
    [ -n "$file" ] || continue
    f="$T/system/system/etc/$file"
    grep -qx "$lib" "$f" || echo "$lib" >> "$f"
done < port/public_libs.txt
ONEUI="$(awk -F= '$1 == "ro.build.version.oneui" {v = $2 + 0; a = int(v / 10000); b = int(v / 100) % 100; c = v % 100
    print a (b || c ? "." b : "") (c ? "." c : "")}' "$T/system/system/build.prop")"
[ -n "$ONEUI" ] || { echo "ro.build.version.oneui not found"; exit 1; }
python3 port/props.py "$T/system/system/build.prop" port/system.prop
ff=system/system/etc/floating_feature.xml
cp "$T/$ff" "$W/floating_feature.src.xml"
python3 port/floating_feature.py "$W/floating_feature.src.xml" "$W/a145f/$ff" port/sff.txt "$T/$ff"
echo "::endgroup::"

echo "::group::vendor"
if is_erofs "$W/a145f/vendor.img"; then
    extract "$W/a145f/vendor.img" "$T/vendor"
    while IFS= read -r p; do [ -n "$p" ] && rm -rf "${T:?}/vendor/$p"; done < "$CI/vendor_debloat.txt"
    python3 port/sepolicy.py "$T/system" "$T/vendor"
    pack vendor "$T/vendor" "$W/a145f/vendor.img"
else
    mkdir -p "$T/vendor/etc"
    debugfs -R "rdump /etc/selinux $T/vendor/etc" "$W/a145f/vendor.img"
    python3 port/sepolicy.py "$T/system" "$T/vendor"
    cp "$W/a145f/vendor.img" "$W/img/vendor.img"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        debugfs -w -R "rm /$p" "$W/img/vendor.img" || debugfs -w -R "rmdir /$p" "$W/img/vendor.img" || true
    done < "$CI/vendor_debloat.txt"
fi
echo "::endgroup::"

echo "::group::pack"
pack system "$T/system" "$W/parts/system.img"
pack product "$T/product" "$W/parts/product.img"
for p in odm vendor_dlkm system_dlkm; do mv "$W/a145f/$p.img" "$W/img/"; done
rm -rf "$T" "$W/parts" "$W/a145f"
echo "::endgroup::"

echo "::group::zip"
sed -E -e "s/OneUI [0-9.]+ [A-Z0-9]+ Base with langsdorffkernel@[^\"]*/OneUI $ONEUI $SRC_PDA Base with langsdorffkernel@${KERNEL_TAG}${KERNEL_VARIANT}/" \
    -e "s/Version [0-9.]+/Version $ROM_VERSION/" tools/updater-script > "$W/updater-script"
grep -q "OneUI $ONEUI $SRC_PDA Base" "$W/updater-script" || { echo "updater-script banner not updated"; exit 1; }
OUT="$W/a14revive@${ROM_VERSION}_${SRC_PDA}.zip"
python3 "$CI/zip.py" "$W/img" "$W/extra" "$W/updater-script" "$OUT" \
    "version=a14revive@$ROM_VERSION" "donor=$SRC_PDA" "target=$TGT_PDA"
echo "zip=$OUT" >> "$GITHUB_OUTPUT"
echo "donor=$SRC_PDA" >> "$GITHUB_OUTPUT"
echo "::endgroup::"
