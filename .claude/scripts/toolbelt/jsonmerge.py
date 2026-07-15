#!/usr/bin/env python3
"""Deep JSON merge: overlay wins on scalars, dicts merge recursively, lists
concatenate with exact-duplicate suppression. This is also the executable
form of the settings-merge rule for adopting projects that already have a
.claude/settings.json (README §adoption).

Usage: jsonmerge.py base.json overlay.json [-o out.json]
Prints merged JSON to stdout unless -o is given.
"""
import argparse
import json
import sys
from pathlib import Path


def deep_merge(base, overlay):
    if isinstance(base, dict) and isinstance(overlay, dict):
        merged = dict(base)
        for key, value in overlay.items():
            merged[key] = deep_merge(base[key], value) if key in base else value
        return merged
    if isinstance(base, list) and isinstance(overlay, list):
        merged = list(base)
        for item in overlay:
            if item not in merged:
                merged.append(item)
        return merged
    return overlay


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("base")
    parser.add_argument("overlay")
    parser.add_argument("-o", "--out")
    args = parser.parse_args(argv)

    base = json.loads(Path(args.base).read_text(encoding="utf-8"))
    overlay = json.loads(Path(args.overlay).read_text(encoding="utf-8"))
    merged = deep_merge(base, overlay)
    text = json.dumps(merged, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
