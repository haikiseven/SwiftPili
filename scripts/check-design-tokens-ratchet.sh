#!/usr/bin/env bash
set -euo pipefail

# Design tokens per-file count ratchet (`11-07-design-regression-guard`).
#
# Scans `SwiftPili/Features` and `SwiftPili/SharedUI` for:
#   - raw_corner_radius: `cornerRadius: <number>`
#   - system_gray:       `Color(.systemGray*)`
#   - system_size_font:  `.font(.system(size:`
#   - direct_color_scheme: `.environment(\.colorScheme,`
#
# Compares per-file counts against `scripts/design-tokens-ratchet-baseline.json`
# and fails if any (rule, file) count increases.
#
# Usage:
#   scripts/check-design-tokens-ratchet.sh                 Compare current counts
#   scripts/check-design-tokens-ratchet.sh --update-baseline
#   scripts/check-design-tokens-ratchet.sh --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_FILE="$REPO_ROOT/scripts/design-tokens-ratchet-baseline.json"

print_help() {
  cat <<'EOF'
check-design-tokens-ratchet.sh — fail when raw design literals in
SwiftPili/Features or SwiftPili/SharedUI increase versus
scripts/design-tokens-ratchet-baseline.json.

Usage:
  check-design-tokens-ratchet.sh
  check-design-tokens-ratchet.sh --update-baseline
  check-design-tokens-ratchet.sh --help
EOF
}

MODE="compare"
for arg in "$@"; do
  case "$arg" in
    --update-baseline)
      MODE="update"
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "error: unrecognized argument: $arg" >&2
      print_help >&2
      exit 2
      ;;
  esac
done

cd "$REPO_ROOT"

python3 - "$BASELINE_FILE" "$MODE" <<'PYEOF'
import json
import pathlib
import re
import sys
from datetime import date

baseline_path, mode = sys.argv[1:3]

ROOTS = [
    pathlib.Path("SwiftPili/Features"),
    pathlib.Path("SwiftPili/SharedUI"),
]

RULES = {
    "raw_corner_radius": re.compile(r"cornerRadius:\s*[0-9]+(?:\.[0-9]+)?"),
    "system_gray": re.compile(r"Color\(\.systemGray[0-9]*\)"),
    "system_size_font": re.compile(r"\.font\(\.system\(size:"),
    "direct_color_scheme": re.compile(r"\.environment\(\\\.colorScheme,"),
}

# Explicit exemptions (R2: listed in the script, not inferred).
EXEMPTIONS = {
    "raw_corner_radius": {
        "SwiftPili/SharedUI/Components/ShareCardRenderer.swift",
        "SwiftPili/SharedUI/Components/ImageDiagnosticsOverlay.swift",
    },
    "system_gray": set(),
    "system_size_font": {
        "SwiftPili/SharedUI/Components/EmoteText.swift",
        "SwiftPili/SharedUI/Components/ImagePreviewView.swift",
        "SwiftPili/SharedUI/Components/ImageDiagnosticsOverlay.swift",
        "SwiftPili/Features/Mine/Views/ImageDiagnosticsView.swift",
        "SwiftPili/Features/Mine/Views/HangReportView.swift",
        "SwiftPili/Features/Mine/Views/PlaybackDebugReportView.swift",
    },
    "direct_color_scheme": {
        "SwiftPili/SharedUI/AppSurface.swift",
        "SwiftPili/SharedUI/Components/CinematicBackdrop.swift",
        "SwiftPili/SharedUI/Components/ImagePreviewView.swift",
        "SwiftPili/Features/Mine/Views/DanmakuSettingsView.swift",
    },
}

files = sorted(p for root in ROOTS for p in root.rglob("*.swift"))

counts = {rule: {} for rule in RULES}
lines_by_rule_file = {rule: {} for rule in RULES}

def strip_line_comment(line: str) -> str:
    in_string = False
    escaped = False
    for idx in range(len(line) - 1):
        ch = line[idx]
        if escaped:
            escaped = False
            continue
        if in_string and ch == "\\":
            escaped = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if not in_string and line[idx : idx + 2] == "//":
            return line[:idx]
    return line


for path in files:
    rel = path.as_posix()
    text = path.read_text(encoding="utf-8")
    for lineno, raw_line in enumerate(text.splitlines(), 1):
        stripped = raw_line.strip()
        if stripped.startswith("//"):
            continue
        code_part = strip_line_comment(raw_line)
        for rule, pattern in RULES.items():
            if rel in EXEMPTIONS.get(rule, set()):
                continue
            matches = list(pattern.finditer(code_part))
            if matches:
                counts[rule][rel] = counts[rule].get(rel, 0) + len(matches)
                lines_by_rule_file[rule].setdefault(rel, []).append((lineno, stripped))

if mode == "update":
    payload = {
        "updated": str(date.today()),
        "rules": {
            rule: dict(sorted(file_counts.items()))
            for rule, file_counts in sorted(counts.items())
        },
    }
    with open(baseline_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
    totals = {r: sum(c.values()) for r, c in counts.items()}
    print(f"Updated {baseline_path}: {totals}")
    sys.exit(0)

try:
    with open(baseline_path, encoding="utf-8") as f:
        baseline_data = json.load(f)
except (OSError, json.JSONDecodeError) as exc:
    print(f"error: could not read baseline file {baseline_path}: {exc}", file=sys.stderr)
    sys.exit(2)

baseline_rules = baseline_data.get("rules", {})
regressions = []
improvements = []

for rule in sorted(RULES):
    base_files = baseline_rules.get(rule, {})
    cur_files = counts.get(rule, {})
    all_files = sorted(set(base_files) | set(cur_files))
    for rel in all_files:
        b = base_files.get(rel, 0)
        c = cur_files.get(rel, 0)
        if c > b:
            regressions.append((rule, rel, b, c))
        elif c < b:
            improvements.append((rule, rel, b, c))

print("==============================================================================")
print("design-tokens count ratchet — per-file regression gate over Features & SharedUI")
print("==============================================================================")
for rule in sorted(RULES):
    b_total = sum(baseline_rules.get(rule, {}).values())
    c_total = sum(counts.get(rule, {}).values())
    diff = c_total - b_total
    print(f"  {rule}: baseline={b_total} current={c_total} ({diff:+d})")

if improvements:
    print(f"\nIMPROVEMENTS — {len(improvements)} (rule, file) pair(s) decreased:")
    for rule, rel, b, c in improvements:
        print(f"  {rule} [{rel}]: {b} -> {c} ({c - b:+d})")

if regressions:
    print(f"\nFAIL: {len(regressions)} (rule, file) pair(s) increased against baseline:", file=sys.stderr)
    for rule, rel, b, c in regressions:
        print(f"  {rule} [{rel}]: {b} -> {c} (+{c - b})", file=sys.stderr)
        for lineno, snippet in lines_by_rule_file[rule].get(rel, []):
            print(f"    line {lineno}: {snippet}", file=sys.stderr)
    sys.exit(1)

print("\nPASS: no (rule, file) count increased against the baseline.")
PYEOF
