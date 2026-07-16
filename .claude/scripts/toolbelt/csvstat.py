#!/usr/bin/env python3
"""Column statistics for a CSV: count, distinct, and (numeric columns)
min/max/mean. For the data-engineer and quant agents.

Usage: csvstat.py <file.csv> [--column NAME]
"""
import argparse
import csv
import statistics
import sys
from pathlib import Path


def column_stats(rows, column):
    values = [row[column] for row in rows if row.get(column) not in (None, "")]
    stats = {"count": len(values), "distinct": len(set(values))}
    numeric = []
    for value in values:
        try:
            numeric.append(float(value))
        except ValueError:
            numeric = None
            break
    if numeric:
        stats.update({
            "min": min(numeric),
            "max": max(numeric),
            "mean": round(statistics.fmean(numeric), 6),
        })
    return stats


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("file")
    parser.add_argument("--column")
    args = parser.parse_args(argv)

    path = Path(args.file)
    if not path.is_file():
        print("csvstat: not a file: " + args.file, file=sys.stderr)
        return 1
    with path.open(encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        columns = reader.fieldnames or []

    if args.column:
        if args.column not in columns:
            print("csvstat: no column " + args.column + " (have: "
                  + ", ".join(columns) + ")", file=sys.stderr)
            return 1
        columns = [args.column]

    print(str(len(rows)) + " row(s)")
    for column in columns:
        stats = column_stats(rows, column)
        parts = [key + "=" + str(value) for key, value in stats.items()]
        print(column + ": " + " ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
