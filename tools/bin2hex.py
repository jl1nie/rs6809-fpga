#!/usr/bin/env python3
"""bin2hex.py [--words] IN OUT [SIZE]: a binary for $readmemh, one byte (or
one big-endian 16-bit word with --words) per line, padded with $FF to SIZE
bytes."""
import sys
args = sys.argv[1:]
words = args and args[0] == "--words"
if words:
    args = args[1:]
data = open(args[0], "rb").read()
size = int(args[2], 0) if len(args) > 2 else len(data)
if len(data) > size:
    sys.exit(f"{args[0]}: {len(data)} bytes, more than {size}")
data = data + b"\xff" * (size - len(data))
if words:
    out = "".join(f"{data[i]:02x}{data[i+1]:02x}\n" for i in range(0, size, 2))
else:
    out = "".join(f"{b:02x}\n" for b in data)
open(args[1], "w").write(out)
