#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/instance.sh"
source "$SCRIPT_DIR/lib/service.sh"
source "$SCRIPT_DIR/lib/supernode_model.sh"
source "$SCRIPT_DIR/tests/framework.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac2n-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

header "supernode defaults"

assert_eq "default port" "$SN_PORT" "7777"
assert_eq "default mgmt port" "$SN_MGMT_PORT" "5645"
assert_eq "default federation empty" "$SN_FEDERATION" ""
assert_eq "default spoofing prot" "$SN_SPOOFING_PROT" "y"
assert_eq "default verbosity" "$SN_VERBOSITY" "0"

header "parse_supernode_conf + generate round-trip"

SN_PORT="8888"
SN_MGMT_PORT="5700"
SN_FEDERATION="myfed"
SN_SPOOFING_PROT="n"
SN_VERBOSITY="2"

local_conf="$TMP_DIR/supernode.conf"
generate_supernode_conf "$local_conf"

assert_file_exists "conf file created" "$local_conf"

parse_supernode_conf "$local_conf"

assert_eq "port round-trips" "$SN_PORT" "8888"
assert_eq "mgmt port round-trips" "$SN_MGMT_PORT" "5700"
assert_eq "federation round-trips" "$SN_FEDERATION" "myfed"
assert_eq "spoofing disabled round-trips" "$SN_SPOOFING_PROT" "n"
assert_eq "verbosity round-trips" "$SN_VERBOSITY" "2"

header "parse_supernode_conf defaults on re-parse"

SN_PORT="1234"
SN_FEDERATION="other"
minimal_conf="$TMP_DIR/minimal.conf"
cat > "$minimal_conf" <<'EOF'
-p=9999
-t=5646
-f
EOF

parse_supernode_conf "$minimal_conf"

assert_eq "port from minimal" "$SN_PORT" "9999"
assert_eq "mgmt port from minimal" "$SN_MGMT_PORT" "5646"
assert_eq "federation reset on minimal" "$SN_FEDERATION" ""
assert_eq "spoofing default on minimal" "$SN_SPOOFING_PROT" "y"
assert_eq "verbosity default on minimal" "$SN_VERBOSITY" "0"

header "parse_supernode_conf missing file"

if parse_supernode_conf "/nonexistent/path" 2>/dev/null; then
    fail "should fail on missing file"
else
    pass "fails on missing file"
fi

header "parse_supernode_conf skips comments and blanks"

comment_conf="$TMP_DIR/comment.conf"
cat > "$comment_conf" <<'EOF'
# This is a comment
-p=4444

# Another comment
-t=5555
-F=testfed
-f
EOF

parse_supernode_conf "$comment_conf"
assert_eq "port from commented conf" "$SN_PORT" "4444"
assert_eq "mgmt from commented conf" "$SN_MGMT_PORT" "5555"
assert_eq "federation from commented conf" "$SN_FEDERATION" "testfed"

test_summary
