#!/usr/bin/env python3
"""Select the committed acceptance scope; this never approves a revision."""
import argparse
import json
from pathlib import Path

from common import required_policy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scope", choices=("routine", "milestone"))
    parser.add_argument("--debugger", action="store_true",
                        help="include native GDB for a substantial debugging regression risk")
    args = parser.parse_args()
    path = Path(__file__).with_name("policy.json")
    path.write_text(json.dumps(required_policy(args.scope, args.debugger), indent=2) + "\n")
    print(f"selected {args.scope}; commit policy.json before acceptance")


if __name__ == "__main__":
    main()
