#!/usr/bin/env python3
"""Apply KEY=VALUE overrides to a build.prop in place (empty value deletes)."""
import sys


def main(prop, overrides):
    want = {}
    with open(overrides) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                k, _, v = line.partition("=")
                want[k] = v
    out, seen = [], set()
    with open(prop) as f:
        for line in f:
            k, sep, _ = line.rstrip("\n").partition("=")
            if sep and k in want:
                seen.add(k)
                if want[k]:
                    out.append(f"{k}={want[k]}\n")
                continue
            out.append(line)
    extra = [f"{k}={v}\n" for k, v in want.items() if v and k not in seen]
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    with open(prop, "w") as f:
        f.writelines(out + extra)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: props.py <build.prop> <overrides>")
    main(*sys.argv[1:])
