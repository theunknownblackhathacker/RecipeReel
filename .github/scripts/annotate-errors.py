#!/usr/bin/env python3
"""Turns the important lines of a failed build/test log into a GitHub error annotation,
so failures are readable from the run summary (and the API) without downloading logs."""
import re
import sys

log_path, title = sys.argv[1], sys.argv[2]
with open(log_path, errors="replace") as f:
    lines = [line.rstrip() for line in f]

pattern = re.compile(r"error:|✘|recorded an issue|Expectation failed|failed|fatal|Caught error")
hits = [line for line in lines if pattern.search(line)][:80]
if not hits:
    hits = lines[-60:]
message = "\n".join(hits)[:30000]
encoded = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::error title={title}::{encoded}")
