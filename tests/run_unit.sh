#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$SCRIPT_DIR/tests/unit"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
ALL_FAILURES=()

for test_file in "$TEST_DIR"/test_*.sh; do
    [[ -f "$test_file" ]] || continue
    echo ""
    printf "━━━ Running %s ━━━\n" "$(basename "$test_file")"

    set +e
    output=$(bash "$test_file" 2>&1)
    rc=$?
    set -e

    echo "$output"

    p=$(echo "$output" | grep -c '✓' || true)
    f=$(echo "$output" | grep -c '✗' || true)
    s=$(echo "$output" | grep -c '○' || true)

    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    TOTAL_SKIP=$((TOTAL_SKIP + s))

    if (( rc != 0 )); then
        ALL_FAILURES+=("$(basename "$test_file")")
    fi
done

echo ""
echo "════════════════════════════════════"
printf "  Total Passed:  %d\n" "$TOTAL_PASS"
printf "  Total Failed:  %d\n" "$TOTAL_FAIL"
printf "  Total Skipped: %d\n" "$TOTAL_SKIP"
echo "════════════════════════════════════"

if (( TOTAL_FAIL > 0 )); then
    echo ""
    echo "Failed test files:"
    for f in "${ALL_FAILURES[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

echo ""
echo "All tests passed."
