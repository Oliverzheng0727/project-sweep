#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
source scripts/build-support.sh
swift build "${BUILD_ARGS[@]}" -c release --arch arm64
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" -c release --arch arm64 --show-bin-path)"
configure_core_link_inputs
CHECK_DIR="$PROJECT_DIR/.build/performance-benchmark"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ProjectSweep-benchmark.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
mkdir -p "$CHECK_DIR"
python3 - "$FIXTURE_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def write(relative, content='fixture'):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
for index in range(2000):
    write(f'src/模块{index // 100:02d}/源码{index:05d}.swift', '// fixture')
for index in range(8000):
    write(f'assets/图标{index // 200:02d}/作品{index:05d}.svg', '<svg xmlns="http://www.w3.org/2000/svg"/>')
for path in ['deep/.agents/skills/demo/SKILL.md', 'deep/__pycache__/module.pyc',
             '__pycache__/nested/module.pyc', 'exports/成品.pdf',
             'exports/Demo.app/Contents/data.txt', 'src-copy/free.swift']:
    write(path)
PY
/usr/bin/git init -q "$FIXTURE_DIR"
/usr/bin/git -C "$FIXTURE_DIR" add src
swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
    -I "$MODULE_DIR" -I Sources/CSQLite -lsqlite3 \
    Tests/Acceptance/ScanBenchmark.swift "${CORE_OBJECTS[@]}" \
    -o "$CHECK_DIR/scan-benchmark"
"$CHECK_DIR/scan-benchmark" "$FIXTURE_DIR"
