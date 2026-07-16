#!/usr/bin/env python3
"""Line/word/char/token-estimate counts. Token estimate = ceil(chars/4).

Usage: count.py <file...>   or   ... | count.py -
"""
import argparse
import math
import sys
from pathlib import Path


def count_text(text):
    return {
        "lines": len(text.splitlines()),
        "words": len(text.split()),
        "chars": len(text),
        "tokens_est": math.ceil(len(text) / 4),
    }


def fmt(name, counts):
    return (name + ": lines=" + str(counts["lines"]) + " words=" + str(counts["words"])
            + " chars=" + str(counts["chars"]) + " tokens_est=" + str(counts["tokens_est"]))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="*", default=["-"],
                        help="files to count, or '-' for stdin (default)")
    parsed = parser.parse_args(argv)
    status = 0
    for arg in parsed.files or ["-"]:
        if arg == "-":
            print(fmt("stdin", count_text(sys.stdin.read())))
        else:
            path = Path(arg)
            if not path.is_file():
                print("count: not a file: " + arg, file=sys.stderr)
                status = 1
                continue
            print(fmt(str(path), count_text(path.read_text(encoding="utf-8", errors="replace"))))
    return status


if __name__ == "__main__":
    sys.exit(main())
