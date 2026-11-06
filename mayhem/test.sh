#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ripwire's own doctest/verification suite (built by mayhem/build.sh into build-tests/).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

T="$SRC/build-tests"
passed=0 ; failed=0

# doctest binaries: parse "[doctest] test cases: N | P passed | F failed | S skipped". A binary that prints no
# summary (missing, crashed, or neutered into a no-op) counts as one failure — exit status alone proves nothing.
for t in csr pagerank strkern oswin32logic; do
  bin="$T/ripwire_test_$t"
  if [ ! -x "$bin" ]; then echo "missing test runner $bin (mayhem/build.sh builds it)" >&2; failed=$((failed+1)); continue; fi
  out="$("$bin" 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -a '^\[doctest\] test cases:' | tail -1)"
  p="$(printf '%s' "$line" | sed -n 's/.*| *\([0-9][0-9]*\) passed.*/\1/p')"
  f="$(printf '%s' "$line" | sed -n 's/.*passed | *\([0-9][0-9]*\) failed.*/\1/p')"
  if [ -z "$p" ] || [ -z "$f" ]; then
    echo "FAIL $t: no doctest summary (rc=$rc)" >&2; failed=$((failed+1)); continue
  fi
  echo "$t: $p passed, $f failed"
  passed=$((passed+p)) ; failed=$((failed+f))
  [ "$rc" -eq 0 ] || { echo "FAIL $t: exit $rc" >&2; [ "$f" -gt 0 ] || failed=$((failed+1)); }
done

# radix: a self-checking gate that prints "radix gate: PASS" on success.
bin="$T/ripwire_test_radix"
if [ -x "$bin" ] && "$bin" 2>&1 | grep -aqx 'radix gate: PASS'; then
  echo "radix: 1 passed"; passed=$((passed+1))
else
  echo "FAIL radix: no 'radix gate: PASS'" >&2; failed=$((failed+1))
fi

emit_ctrf "doctest" "$passed" "$failed" 0
