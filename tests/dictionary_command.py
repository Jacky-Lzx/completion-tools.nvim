#!/usr/bin/env python3
"""WordNet-shaped fixture with delayed, empty and failed lookups."""
import json
import os
from pathlib import Path
import sys
import time

word, option = sys.argv[1:]
assert option == "-over"
if os.environ.get("COMPLETION_DICTIONARY_TRACE"):
    with Path(os.environ["COMPLETION_DICTIONARY_TRACE"]).open("a") as trace:
        trace.write(json.dumps({"word": word, "pid": os.getpid()}) + "\n")
if word in ("slow", "timeout") or word.endswith("Slow"):
    time.sleep(2)
if word == "empty":
    sys.exit(0)
if word == "failed":
    print("unavailable dictionary", file=sys.stderr)
    sys.exit(1)
print(f"Overview of {word}\n\nMeaning of {word}.")
sys.exit(2)  # WordNet returns the sense count, not a conventional success code.
