#!/usr/bin/env python3
"""Build the TWRP package from partition images, same layout as romkit zip.

    zip.py <img_dir> <extra_dir> <updater-script> <out.zip> key=value...

<img_dir> holds one <part>.img per super partition. <extra_dir> holds files
copied as they are (update-binary, unsparse_super_empty.img, boot.img, ...).
key=value pairs end up in build_info.txt and META-INF/com/android/metadata.
"""
import datetime
import os
import shutil
import sys
import zipfile

BLOCK = 4096
GROUP = "group_basic"
GROUP_SIZE = 7713325056
PARTS = ["system", "vendor", "product", "odm", "vendor_dlkm", "system_dlkm"]
EXTRA = {
    "update-binary": "META-INF/com/google/android/update-binary",
    "unsparse_super_empty.img": "unsparse_super_empty.img",
    "boot.img": "boot.img",
    "vendor_boot.img": "vendor_boot.img",
    "vbmeta.img": "vbmeta.img",
    "up_param.bin": "up_param.bin",
}
DIRS = ["META-INF/", "META-INF/com/", "META-INF/com/android/",
        "META-INF/com/google/", "META-INF/com/google/android/"]


def op_list(sizes):
    out = ["# Remove all existing dynamic partitions and groups before applying full OTA",
           "remove_all_groups",
           f"# Add group {GROUP} with maximum size {GROUP_SIZE}",
           f"add_group {GROUP} {GROUP_SIZE}"]
    for p in PARTS:
        out += [f"# Add partition {p} to group {GROUP}", f"add {p} {GROUP}"]
    for p in PARTS:
        out += [f"# Grow partition {p} from 0 to {sizes[p]}", f"resize {p} {sizes[p]}"]
    return "\n".join(out)


def main(img_dir, extra_dir, script, out, *kv):
    info = dict(x.split("=", 1) for x in kv)
    sizes = {}
    for p in PARTS:
        sizes[p] = os.path.getsize(os.path.join(img_dir, p + ".img"))
        if sizes[p] % BLOCK:
            sys.exit(f"{p}.img is not block aligned")
    total = sum(sizes.values())
    print("partition sizes:", sizes)
    print(f"total {total} of {GROUP_SIZE} ({total / GROUP_SIZE * 100:.1f}%)")
    if total > GROUP_SIZE:
        sys.exit("does not fit in super")

    with zipfile.ZipFile(out, "w", allowZip64=True) as z:
        for d in DIRS:
            zi = zipfile.ZipInfo(d)
            zi.external_attr = (0o40755 << 16) | 0x10
            z.writestr(zi, b"")
        for src, name in EXTRA.items():
            z.write(os.path.join(extra_dir, src), name, compress_type=zipfile.ZIP_STORED)
        for p in PARTS:
            blocks = sizes[p] // BLOCK
            # v4, one "new" command, no "erase": a failing BLKDISCARD aborts the update
            z.writestr(f"{p}.transfer.list", f"4\n{blocks}\n0\n0\nnew 2,0,{blocks}\n")
            z.writestr(f"{p}.patch.dat", b"")
            zi = zipfile.ZipInfo(f"{p}.new.dat")
            zi.compress_type = zipfile.ZIP_STORED
            zi.file_size = sizes[p]
            with open(os.path.join(img_dir, p + ".img"), "rb") as fsrc, z.open(zi, "w", force_zip64=True) as fdst:
                shutil.copyfileobj(fsrc, fdst, 1 << 22)
            print(f"wrote {p}.new.dat ({blocks} blocks)")
        z.writestr("dynamic_partitions_op_list", op_list(sizes))
        z.writestr("META-INF/com/google/android/updater-script", open(script).read())
        z.writestr("build_info.txt",
                   f"name=a14revive\nversion={info['version']}\ndevice=a14\n"
                   f"date={datetime.date.today().isoformat()}\ndonor={info['donor']}\n")
        z.writestr("META-INF/com/android/metadata",
                   f"ota-type=BLOCK\npost-build-incremental={info['target']}\npre-device=a14\n")
    print("package:", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
