#!/usr/bin/env python3
"""Apply KEY=VALUE overrides to floating_feature.xml (empty value deletes)."""
import re
import sys

RE = re.compile(r"^(\s*)<(SEC_FLOATING_FEATURE_[A-Z0-9_]+)>.*</\2>\s*$")
END = "</SecFloatingFeatureSet>"


def main(xml, overrides):
    want = {}
    with open(overrides, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            k, _, v = line.partition("=")
            if not k.startswith("SEC_FLOATING_FEATURE_"):
                sys.exit(f"malformed line in {overrides}: {line}")
            want[k] = v
    out, seen = [], set()
    with open(xml, encoding="utf-8", newline="") as f:
        for line in f:
            m = RE.match(line.rstrip("\r\n"))
            if m and m.group(2) in want:
                k = m.group(2)
                seen.add(k)
                if want[k]:
                    out.append(f"{m.group(1)}<{k}>{want[k]}</{k}>\n")
                continue
            if line.strip() == END:
                out += [f"    <{k}>{v}</{k}>\n" for k, v in want.items() if v and k not in seen]
            out.append(line)
    if not any(l.strip() == END for l in out):
        sys.exit(f"{END} not found in {xml}")
    with open(xml, "w", encoding="utf-8", newline="") as f:
        f.writelines(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: sff.py <floating_feature.xml> <overrides>")
    main(*sys.argv[1:])
