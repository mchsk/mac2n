#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/instance.sh"
source "$SCRIPT_DIR/tests/framework.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac2n-test-core.XXXXXX")
trap 'rm -rf "$TMP_DIR"; rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT

header "constants"

assert_eq "CONFIG_DIR set" "$CONFIG_DIR" "$HOME/.config/n2n"
assert_eq "INSTANCES_DIR set" "$INSTANCES_DIR" "$HOME/.config/n2n/instances"
assert_eq "PLIST_DIR set" "$PLIST_DIR" "/Library/LaunchDaemons"
assert_eq "PLIST_PREFIX set" "$PLIST_PREFIX" "org.ntop.n2n-edge"
assert_eq "SN_PLIST_LABEL set" "$SN_PLIST_LABEL" "org.ntop.n2n-supernode"
assert_eq "LOG_DIR set" "$LOG_DIR" "/var/log"

header "lock file path"

assert_match "lock file in config dir" "$LOCK_FILE" "\.config/n2n/\.mac2n\.lock"

header "acquire_lock + release_lock"

ORIG_LOCK="$LOCK_FILE"
LOCK_FILE="$TMP_DIR/.test-lock"
_LOCK_HELD=false

acquire_lock
if [[ -f "$LOCK_FILE" ]]; then
    pass "lock file created"
else
    fail "lock file not created"
fi

lock_content=$(cat "$LOCK_FILE")
assert_eq "lock contains PID" "$lock_content" "$$"
assert_eq "_LOCK_HELD is true" "$_LOCK_HELD" "true"

release_lock
if [[ -f "$LOCK_FILE" ]]; then
    fail "lock file not removed after release"
else
    pass "lock file removed after release"
fi
assert_eq "_LOCK_HELD is false after release" "$_LOCK_HELD" "false"

header "stale lock cleanup"

echo "99999999" > "$LOCK_FILE"
acquire_lock
assert_eq "stale lock replaced" "$(cat "$LOCK_FILE")" "$$"
pass "acquired lock after stale PID"
release_lock

header "cleanup files"

test_file="$TMP_DIR/cleanup_test"
touch "$test_file"
_CLEANUP_FILES+=("$test_file")

assert_file_exists "cleanup file exists before cleanup" "$test_file"

header "version"

assert_match "VERSION is set" "$VERSION" "^[0-9]"

header "ensure_sudo (non-interactive check)"

if sudo -n true 2>/dev/null; then
    pass "sudo available (cached)"
else
    skip "sudo not cached (expected in CI)"
fi

LOCK_FILE="$ORIG_LOCK"

test_summary
