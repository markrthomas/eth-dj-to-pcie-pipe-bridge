#!/usr/bin/env python3
"""Fail if a cocotb results.xml is missing, empty, or contains a failure/error."""
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1] if len(sys.argv) > 1 else "results.xml"
try:
    root = ET.parse(path).getroot()
except (OSError, ET.ParseError) as e:
    print(f"COCOTB FAIL: cannot read {path}: {e}")
    sys.exit(1)
cases = root.findall(".//testcase")
bad = [c.get("name") for c in cases if c.find("failure") is not None or c.find("error") is not None]
if not cases or bad:
    print(f"COCOTB FAIL: {len(cases)} test(s), failing: {bad}")
    sys.exit(1)
print(f"COCOTB PASS: {len(cases)} test(s): {[c.get('name') for c in cases]}")
