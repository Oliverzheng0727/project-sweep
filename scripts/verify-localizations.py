#!/usr/bin/env python3
"""Fail when a static Chinese source string lacks an English translation."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
STRINGS = ROOT / "Sources/CleanupCore/Resources/en.lproj/Localizable.strings"
SOURCE_DIRS = (ROOT / "Sources/CleanupCore", ROOT / "Sources/ProjectSweepApp")

entry_pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.MULTILINE)
source_pattern = re.compile(r'"([^"\n]*[\u3400-\u9fff][^"\n]*)"')

entries = entry_pattern.findall(STRINGS.read_text(encoding="utf-8"))
keys = [key for key, _ in entries]
duplicates = sorted({key for key in keys if keys.count(key) > 1})
translations = dict(entries)
missing: list[tuple[Path, str]] = []

for source_dir in SOURCE_DIRS:
    for path in sorted(source_dir.rglob("*.swift")):
        if path.name == "AppLocalization.swift":
            continue
        for match in source_pattern.finditer(path.read_text(encoding="utf-8")):
            source = match.group(1)
            if r"\(" not in source and source not in translations:
                missing.append((path.relative_to(ROOT), source))

if duplicates:
    print("Duplicate English localization keys:", file=sys.stderr)
    for key in duplicates:
        print(f"  {key}", file=sys.stderr)

if missing:
    print("Static Chinese strings missing from the English localization:", file=sys.stderr)
    for path, source in missing:
        print(f"  {path}: {source}", file=sys.stderr)

if duplicates or missing:
    raise SystemExit(1)

print(f"Localization coverage OK: {len(entries)} English strings, no duplicate keys")
