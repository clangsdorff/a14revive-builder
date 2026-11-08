# Stock based build, sourced from build.sh. Everything comes from one firmware.

echo "::group::download"
download "$SOURCE_MODEL" "$SOURCE_CSC" "$W/src" "${SOURCE_FW:-}"; SRC_PDA="${FW%%/*}"
echo "::endgroup::"

echo "::group::unpack"
super "$W/src" "$W/parts" system vendor product odm vendor_dlkm system_dlkm
unzip -p "$W"/src/*.zip 'BL_*.tar.md5' | tar -xO up_param.bin.lz4 | lz4 -d > "$W/extra/up_param.bin"
rm -rf "$W/src"
for p in system vendor product; do
    is_erofs "$W/parts/$p.img" || { echo "$p.img is not erofs"; exit 1; }
    extract "$W/parts/$p.img" "$T/$p"
done
echo "::endgroup::"

kernel

echo "::group::patch apps"
rm -rf apks dist unpacked apktool_frameworks
mkdir -p apks
cp "$SIGN_KEY" platform.pk8
cp "$SIGN_CERT" platform.x509.pem
cp "$T/system/system/framework/framework-res.apk" apks/
java -jar apktool.jar if apks/framework-res.apk -p apktool_frameworks
for p in patches/*_out.patch; do
    b="$(basename "$p" _out.patch)"
    hit="$(find "$T/system/system" "$T/product" -type f \( -name "$b.jar" -o -name "$b.apk" \) \
        -not -path '*/oat/*' | head -n 1)"
    [ -n "$hit" ] || { echo "$b: not found in $SOURCE_MODEL"; exit 1; }
    t="$(basename "$hit")"
    cp "$hit" apks/
    bash apply_patches.sh "$t" "${b}_out.patch"
    cat "dist/${b}_patched.${t##*.}" > "$hit"
    rm -f "$hit.prof" "$hit.bprof"
done
rm -f platform.pk8 platform.x509.pem
echo "::endgroup::"

echo "::group::deodex"
rm -rf "$T/system/system/framework/arm" "$T/system/system/framework/arm64" \
    "$T/system/system/etc/boot-image.prof" "$T/system/system/etc/boot-image.bprof"
find "$T/system" "$T/product" -depth -type d -name oat -exec rm -rf {} +
find "$T/system/system/framework" -type f -name '*.vdex' -delete
echo "::endgroup::"

echo "::group::system"
while IFS= read -r p; do [ -n "$p" ] && rm -rf "${T:?}/$p"; done < port/debloat.txt
while IFS= read -r p; do [ -n "$p" ] && rm -rf "${T:?}/vendor/$p"; done < port/vendor_debloat.txt
python3 "$CI/put_files.py" port/files "$T"
ONEUI="$(oneui "$T/system/system/build.prop")"
python3 "$CI/props.py" "$T/system/system/build.prop" port/system.prop
python3 "$CI/props.py" "$T/vendor/build.prop" port/vendor.prop
python3 "$CI/sff.py" "$T/system/system/etc/floating_feature.xml" port/sff.txt
echo "::endgroup::"

echo "::group::pack"
for p in system vendor product; do pack "$p" "$T/$p" "$W/parts/$p.img"; done
for p in odm vendor_dlkm system_dlkm; do mv "$W/parts/$p.img" "$W/img/"; done
rm -rf "$T" "$W/parts"
echo "::endgroup::"

make_zip "$SRC_PDA" "$SRC_PDA"
