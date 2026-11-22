#!/usr/bin/env bash
set -euo pipefail

# swiftlint count ratchet — CB-9's third option.
#
# Rather than weakening lint thresholds or leaving SwiftLint unguarded, this
# not do both halves badly": raise file_length/line_length to what the
# project holds (which today means blessing an 8,462-line file and separately
# fixing a 106-site force_unwrapping residual), or drop `--strict` and call
# swiftlint advisory (which is how the debt doubled with nobody watching).
# Both were rejected. This script is the third option: it does not touch a
# single threshold or fix a single violation. It asserts that no rule's
# violation COUNT, AT A GIVEN SEVERITY, has increased against a checked-in
# baseline (scripts/swiftlint-ratchet-baseline.json). That makes today's real
# debt the metric, stops it from growing further unobserved, and requires
# zero cleanup to turn on.
#
# Counts are split by severity — swiftlint's own JSON `severity` field
# ("error"/"warning"), never inferred from the warning/error thresholds in
# .swiftlint.yml — and compared independently per (rule, severity) pair. This
# is not cosmetic: `file_length`'s error tier (>1000 lines) is exactly what
# makes `swiftlint lint --strict` unpassable, while its warning tier (>500
# lines) is not. A blended single count per rule would let a file crossing
# INTO the error tier net to zero against an unrelated file dropping below
# the warning tier — the exact failure mode a ratchet exists to catch.
#
# ⚠️ Read this before trusting a green run: this is a REGRESSION gate, not a
# correctness gate. It cannot tell you the code is clean — only that the
# known debt, rule by rule and severity by severity, did not grow. A "swap"
# — one force_unwrapping site fixed and a different force_unwrapping site
# introduced elsewhere in the same commit, AT THE SAME SEVERITY — nets to
# zero and PASSES. So does moving a violation from one file to another.
# Nothing here inspects which file a violation lives in when deciding
# pass/fail (file names are surfaced on failure purely as a debugging aid,
# see below).
#
# Violation counts are swiftlint-version-dependent (rule implementations,
# even default thresholds, change between releases) — comparing counts
# produced by two different swiftlint versions is meaningless and produces
# failures (or false passes) that have nothing to do with the code. So the
# baseline records the exact version it was measured with, and this script
# REFUSES to compare against a baseline recorded by a different version
# rather than silently comparing anyway.
#
# Usage:
#   scripts/check-swiftlint-ratchet.sh                 Compare current counts
#                                                       to the baseline; fail
#                                                       if any rule increased.
#   scripts/check-swiftlint-ratchet.sh --update-baseline
#                                                       Recompute counts and
#                                                       overwrite the baseline
#                                                       file with them (and
#                                                       the running swiftlint
#                                                       version). Use this
#                                                       after a deliberate
#                                                       fix run to lock in an
#                                                       improvement, or after
#                                                       a deliberate,
#                                                       reviewed increase.
#   scripts/check-swiftlint-ratchet.sh --help           Show this text.
#
# Environment:
#   SWIFTLINT_BIN   Path to the swiftlint binary to run (default: "swiftlint"
#                    resolved via PATH). Set this in CI to point at a
#                    downloaded, pinned binary rather than relying on one
#                    being preinstalled.
#
# Why python3 and not jq for the JSON handling below: jq is not guaranteed
# present (this repo's own Linux dev box does not have it installed), while
# python3 is guaranteed on every GitHub-hosted ubuntu-latest runner and is
# already present here — using it avoids adding a new tool dependency to
# either environment.
#
# Exit status capture, not a pipeline: `swiftlint lint` exits non-zero
# (documented: 2) whenever any ERROR-severity violation exists — which is
# the normal, expected case here, since the repo has real, un-fixed
# violations at error severity (e.g. file_length errors on files over 1000
# lines). That exit code is NOT this script's pass/fail signal — the
# rule-by-rule comparison below is — so it is captured explicitly with
# `|| lint_status=$?` (never allowed to trip `set -e`) and swiftlint's own
# stdout/stderr are captured via plain redirection (`>`, not a pipe), so
# there is no pipeline stage whose own exit status could stand in for
# swiftlint's. A genuine tool failure (crash, bad config, no such rule) is
# instead caught below by checking that stdout is valid, parseable JSON —
# that check fires regardless of swiftlint's exit code.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_FILE="$REPO_ROOT/scripts/swiftlint-ratchet-baseline.json"
SWIFTLINT_BIN="${SWIFTLINT_BIN:-swiftlint}"

print_help() {
  cat <<'EOF'
check-swiftlint-ratchet.sh — fail when a swiftlint rule's violation count, AT A
GIVEN SEVERITY, increases versus the checked-in baseline
(scripts/swiftlint-ratchet-baseline.json).

This is a REGRESSION gate, not a correctness gate: it does not know or care
whether the codebase is clean, only whether each (rule, severity) pair's count
went up. A "swap" (one violation of a rule fixed, a different one of the same
rule and severity introduced) nets to zero and passes. Severity comes from
swiftlint's own report, not from .swiftlint.yml's thresholds, so a file
crossing from warning-tier into error-tier on a rule like file_length is
reported and gated distinctly from one crossing the other way.

Usage:
  check-swiftlint-ratchet.sh                  Compare current counts to the
                                               baseline; exit non-zero if any
                                               rule's count increased.
  check-swiftlint-ratchet.sh --update-baseline
                                               Overwrite the baseline with the
                                               current counts and the running
                                               swiftlint version. Use after a
                                               deliberate, reviewed change to
                                               the counts (an improvement you
                                               want to lock in, or a reviewed
                                               increase).
  check-swiftlint-ratchet.sh --help           Show this text.

Environment:
  SWIFTLINT_BIN   Path to the swiftlint binary to run (default: "swiftlint").

The baseline records the swiftlint version it was measured with. Comparing
against a baseline recorded by a different version is refused outright,
because violation counts are version-dependent and a cross-version
comparison would fail (or pass) for reasons that have nothing to do with the
code.
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

if ! command -v "$SWIFTLINT_BIN" >/dev/null 2>&1; then
  echo "error: swiftlint binary not found: '$SWIFTLINT_BIN' (set SWIFTLINT_BIN or install swiftlint)" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not found — required to parse swiftlint's JSON report" >&2
  exit 2
fi

CURRENT_VERSION="$("$SWIFTLINT_BIN" version)"

# Fail fast on a version mismatch BEFORE paying for a full lint run — except
# in update mode, where recording a new version is exactly the point.
if [[ "$MODE" == "compare" ]]; then
  if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "error: no baseline file at $BASELINE_FILE — run with --update-baseline first" >&2
    exit 2
  fi
  BASELINE_VERSION="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get('swiftlint_version', ''))
" "$BASELINE_FILE")"
  if [[ -z "$BASELINE_VERSION" ]]; then
    echo "error: baseline file $BASELINE_FILE has no 'swiftlint_version' field — cannot verify it is comparable" >&2
    exit 2
  fi
  if [[ "$BASELINE_VERSION" != "$CURRENT_VERSION" ]]; then
    cat >&2 <<EOF
REFUSING TO COMPARE: violation counts are swiftlint-version-dependent.
  baseline recorded with swiftlint $BASELINE_VERSION
  currently installed:            $CURRENT_VERSION
Install swiftlint $BASELINE_VERSION and re-run, or — only after confirming by
eye that the count differences are a version artifact and not a real
regression — re-run with --update-baseline under $CURRENT_VERSION to rebase
the baseline onto that version.
EOF
    exit 2
  fi
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
LINT_JSON="$WORKDIR/swiftlint-report.json"
LINT_STDERR="$WORKDIR/swiftlint-stderr.log"

cd "$REPO_ROOT"
lint_status=0
"$SWIFTLINT_BIN" lint --reporter json --quiet >"$LINT_JSON" 2>"$LINT_STDERR" || lint_status=$?

if [[ -s "$LINT_STDERR" ]]; then
  echo "--- swiftlint stderr (diagnostic only — not the pass/fail signal) ---"
  cat "$LINT_STDERR"
  echo "----------------------------------------------------------------------"
fi
echo "swiftlint lint exit status: $lint_status (non-zero here is normal — see this script's header comment; it is not what decides pass/fail)"

# The aggregation/comparison/baseline-write logic below is embedded here
# (rather than a second .py file) so the ratchet is exactly one file to
# review, copy, or delete. It is invoked as `python3 - <args>` — the `-`
# tells python3 to read the script from stdin (the heredoc), and everything
# after it on this command line is left as sys.argv[1:] for that script.
python3 - "$LINT_JSON" "$BASELINE_FILE" "$CURRENT_VERSION" "$MODE" <<'PYEOF'
import json
import os
import sys
from collections import Counter
from datetime import date

lint_json_path, baseline_path, current_version, mode = sys.argv[1:5]

try:
    with open(lint_json_path) as f:
        violations = json.load(f)
except (OSError, json.JSONDecodeError) as exc:
    print(f"error: swiftlint did not produce a parseable JSON report ({exc}) — "
          f"see the stderr dump above for the likely cause", file=sys.stderr)
    sys.exit(2)

if not isinstance(violations, list):
    print("error: swiftlint's JSON report was not a list of violations as expected", file=sys.stderr)
    sys.exit(2)

# counts[rule][severity] = n. Severity comes straight from swiftlint's own
# JSON `severity` field (lowercased: "Error" -> "error", "Warning" ->
# "warning") — never inferred from the configured warning/error thresholds in
# .swiftlint.yml, which can change independently of what a given run reports.
# Splitting by severity is not cosmetic: file_length's error tier (>1000
# lines) is exactly what makes `swiftlint lint --strict` unpassable, and a
# blended count would let a file crossing INTO the error tier net to zero
# against an unrelated file dropping below the warning tier.
counts = {}
files_by_rule_severity = {}
for v in violations:
    rule = v.get("rule_id", "<unknown_rule>")
    severity = str(v.get("severity", "<unknown_severity>")).lower()
    counts.setdefault(rule, {})
    counts[rule][severity] = counts[rule].get(severity, 0) + 1
    files_by_rule_severity.setdefault((rule, severity), Counter())[v.get("file", "<unknown_file>")] += 1

total = sum(n for sevmap in counts.values() for n in sevmap.values())
total_by_severity = {}
for sevmap in counts.values():
    for sev, n in sevmap.items():
        total_by_severity[sev] = total_by_severity.get(sev, 0) + n

if mode == "update":
    baseline = {
        "swiftlint_version": current_version,
        "generated": date.today().isoformat(),
        "total": total,
        "total_by_severity": total_by_severity,
        "rules": {rule: counts[rule] for rule in sorted(counts)},
    }
    with open(baseline_path, "w") as f:
        json.dump(baseline, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"Baseline written: {baseline_path}")
    print(f"  swiftlint version: {current_version}")
    print(f"  total violations:  {total}  (by severity: {dict(sorted(total_by_severity.items()))})")
    print("Review the diff (git diff -- scripts/swiftlint-ratchet-baseline.json) before committing it —")
    print("this file is meant to be reviewed like any other change to a checked-in gate.")
    sys.exit(0)

# --- compare mode ---
if not os.path.exists(baseline_path):
    print(f"error: no baseline file at {baseline_path} — run with --update-baseline first", file=sys.stderr)
    sys.exit(2)

with open(baseline_path) as f:
    baseline = json.load(f)

baseline_rules = baseline.get("rules", {})
for rule, sevmap in baseline_rules.items():
    if not isinstance(sevmap, dict):
        print(f"error: baseline entry for '{rule}' is not severity-keyed ({sevmap!r}) — this baseline "
              f"predates the per-severity ratchet; regenerate it with --update-baseline (do not hand-edit "
              f"it into the new shape)", file=sys.stderr)
        sys.exit(2)

baseline_total_field = baseline.get("total")
baseline_total_computed = sum(n for sevmap in baseline_rules.values() for n in sevmap.values())
if baseline_total_field is not None and baseline_total_field != baseline_total_computed:
    print(f"warning: baseline's 'total' field ({baseline_total_field}) does not match the sum of "
          f"its own 'rules' entries ({baseline_total_computed}) — the baseline file may have been "
          f"hand-edited inconsistently", file=sys.stderr)

all_keys = set()
for rule, sevmap in baseline_rules.items():
    for sev in sevmap:
        all_keys.add((rule, sev))
for rule, sevmap in counts.items():
    for sev in sevmap:
        all_keys.add((rule, sev))

regressions = []
improvements = []
for rule, sev in sorted(all_keys):
    b = baseline_rules.get(rule, {}).get(sev, 0)
    c = counts.get(rule, {}).get(sev, 0)
    if c > b:
        regressions.append((rule, sev, b, c))
    elif c < b:
        improvements.append((rule, sev, b, c))

print("=" * 78)
print("swiftlint count ratchet — a REGRESSION gate, not a correctness gate.")
print("It asserts only that no (rule, severity) pair's violation count increased")
print("versus the checked-in baseline. A swap (one violation of a rule/severity")
print("fixed, a different one of the SAME rule/severity introduced elsewhere)")
print("nets to zero and PASSES.")
print("=" * 78)
print(f"swiftlint version: {current_version}")
print(f"total violations: baseline={baseline_total_computed} current={total} "
      f"({'+' if total > baseline_total_computed else ''}{total - baseline_total_computed})")
print(f"  by severity — baseline: {dict(sorted(baseline.get('total_by_severity', {}).items()))}  "
      f"current: {dict(sorted(total_by_severity.items()))}")
print()

if regressions:
    print(f"REGRESSIONS — {len(regressions)} (rule, severity) pair(s) increased:")
    for rule, sev, b, c in regressions:
        print(f"  {rule} [{sev}]: {b} -> {c} (+{c - b})")
        rule_files = files_by_rule_severity.get((rule, sev))
        if rule_files:
            print(f"      files currently reporting '{rule}' at {sev} severity (this is every current")
            print(f"      offender at this severity, not a diff against the baseline — the baseline stores")
            print(f"      only per-rule-per-severity totals, so it cannot say which occurrence is new;")
            print(f"      use this list as a starting point):")
            for fpath, n in sorted(rule_files.items(), key=lambda kv: (-kv[1], kv[0])):
                try:
                    rel = os.path.relpath(fpath)
                except ValueError:
                    rel = fpath
                print(f"        {n:3d}  {rel}")
    print()

if improvements:
    print(f"IMPROVEMENTS — {len(improvements)} (rule, severity) pair(s) decreased (this does not fail the gate):")
    for rule, sev, b, c in improvements:
        print(f"  {rule} [{sev}]: {b} -> {c} ({c - b})")
    print()
    print("NOTICE: the counts above decreased. This gate does not update itself — until")
    print("someone runs `scripts/check-swiftlint-ratchet.sh --update-baseline` and commits the")
    print("result, the OLD (higher) baseline stays checked in, so a later regression back up to")
    print("the old number would still incorrectly pass. Lock the improvement in now.")
    print()

if regressions:
    print(f"FAIL: {len(regressions)} (rule, severity) pair(s) regressed against the baseline.")
    sys.exit(1)

print("PASS: no (rule, severity) pair's violation count increased against the baseline.")
sys.exit(0)
PYEOF
