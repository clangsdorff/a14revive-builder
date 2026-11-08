#!/usr/bin/env python3
"""Copy <files>/<partition>/... into <tree>/<partition>/...

Existing files keep their xattrs and owner. New files and directories get
root ownership and the partition's default SELinux label.
"""
import os
import shutil
import sys

CTX = {
    "system": b"u:object_r:system_file:s0\0",
    "product": b"u:object_r:system_file:s0\0",
    "vendor": b"u:object_r:vendor_file:s0\0",
}


def new(path, mode, ctx):
    os.chown(path, 0, 0)
    os.chmod(path, mode)
    os.setxattr(path, "security.selinux", ctx)


def main(files, tree):
    for part in sorted(os.listdir(files)):
        if part not in CTX:
            sys.exit(f"unknown partition: {part}")
        ctx = CTX[part]
        src_root = os.path.join(files, part)
        dst_root = os.path.join(tree, part)
        for d, dirs, names in os.walk(src_root):
            dst_dir = os.path.join(dst_root, os.path.relpath(d, src_root))
            if not os.path.isdir(dst_dir):
                os.mkdir(dst_dir)
                new(dst_dir, 0o755, ctx)
            for n in names:
                if n == ".DS_Store":
                    continue
                dst = os.path.join(dst_dir, n)
                created = not os.path.exists(dst)
                with open(os.path.join(d, n), "rb") as i, open(dst, "wb") as o:
                    shutil.copyfileobj(i, o)
                if created:
                    new(dst, 0o644, ctx)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: put_files.py <files> <tree>")
    main(*sys.argv[1:])
