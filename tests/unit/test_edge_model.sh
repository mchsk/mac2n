#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/instance.sh"
source "$SCRIPT_DIR/lib/service.sh"
source "$SCRIPT_DIR/lib/edge_model.sh"
source "$SCRIPT_DIR/tests/framework.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac2n-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

header "reset_edge_defaults"

EDGE_COMMUNITY="test"
reset_edge_defaults
assert_eq "community reset to empty" "$EDGE_COMMUNITY" ""
assert_eq "cipher reset to 3" "$EDGE_CIPHER" "3"
assert_eq "MTU reset to 1290" "$EDGE_MTU" "1290"
assert_eq "routing reset to n" "$EDGE_ROUTING" "n"
assert_eq "mgmt port reset to 5644" "$EDGE_MGMT_PORT" "5644"

header "parse_edge_conf + generate round-trip"

EDGE_BIN="/opt/mac2n/sbin/edge"

reset_edge_defaults
EDGE_COMMUNITY="testnet"
EDGE_KEY="MySecretKey123"
EDGE_CIPHER="4"
EDGE_IP="10.55.0.1"
EDGE_CIDR="16"
EDGE_SUPERNODE="sn.example.com:7777"
EDGE_SUPERNODE2="sn2.example.com:7778"
EDGE_MTU="1400"
EDGE_ROUTING="y"
EDGE_MULTICAST="y"
EDGE_COMPRESSION="1"
EDGE_MAC="aa:bb:cc:dd:ee:ff"
EDGE_LOCAL_PORT="5000"
EDGE_MGMT_PORT="5650"
EDGE_SN_SELECT="rtt"
EDGE_DESCRIPTION="test-node"
EDGE_ROUTES="10.0.0.0/8:10.55.0.254"
EDGE_VERBOSITY="2"

local_conf="$TMP_DIR/edge.conf"
generate_edge_conf "$local_conf" "mytest"

assert_file_exists "conf file created" "$local_conf"

# Parse it back
parse_edge_conf "$local_conf"

assert_eq "community round-trips" "$EDGE_COMMUNITY" "testnet"
assert_eq "key round-trips" "$EDGE_KEY" "MySecretKey123"
assert_eq "cipher round-trips" "$EDGE_CIPHER" "4"
assert_eq "IP round-trips" "$EDGE_IP" "10.55.0.1"
assert_eq "CIDR round-trips" "$EDGE_CIDR" "16"
assert_eq "supernode round-trips" "$EDGE_SUPERNODE" "sn.example.com:7777"
assert_eq "backup SN round-trips" "$EDGE_SUPERNODE2" "sn2.example.com:7778"
assert_eq "MTU round-trips" "$EDGE_MTU" "1400"
assert_eq "routing round-trips" "$EDGE_ROUTING" "y"
assert_eq "multicast round-trips" "$EDGE_MULTICAST" "y"
assert_eq "compression round-trips" "$EDGE_COMPRESSION" "1"
assert_eq "MAC round-trips" "$EDGE_MAC" "aa:bb:cc:dd:ee:ff"
assert_eq "local port round-trips" "$EDGE_LOCAL_PORT" "5000"
assert_eq "mgmt port round-trips" "$EDGE_MGMT_PORT" "5650"
assert_eq "SN select round-trips" "$EDGE_SN_SELECT" "rtt"
assert_eq "description round-trips" "$EDGE_DESCRIPTION" "test-node"
assert_eq "routes round-trips" "$EDGE_ROUTES" "10.0.0.0/8:10.55.0.254"
assert_eq "verbosity round-trips" "$EDGE_VERBOSITY" "2"

header "build_edge_display_cmd"

local_display=$(build_edge_display_cmd)
assert_match "display contains sudo" "$local_display" "^sudo "
assert_match "display masks key" "$local_display" "-k '\\*\\*\\*'"
assert_match "display contains community" "$local_display" "-c testnet"

header "cipher_name / compression_name"

assert_eq "cipher 1 = None" "$(cipher_name 1)" "None (no encryption)"
assert_eq "cipher 3 = AES" "$(cipher_name 3)" "AES-256-CBC"
assert_eq "cipher 4 = ChaCha" "$(cipher_name 4)" "ChaCha20"
assert_eq "compression 0 = None" "$(compression_name 0)" "None"
assert_eq "compression 1 = LZO1X" "$(compression_name 1)" "LZO1X"
assert_eq "compression 2 = ZSTD" "$(compression_name 2)" "ZSTD"

header "parse_edge_conf edge cases"

empty_conf="$TMP_DIR/empty.conf"
: > "$empty_conf"
reset_edge_defaults
parse_edge_conf "$empty_conf"
assert_eq "empty conf keeps default cipher" "$EDGE_CIPHER" "3"
assert_eq "empty conf keeps default MTU" "$EDGE_MTU" "1290"
assert_eq "empty conf community empty" "$EDGE_COMMUNITY" ""

if parse_edge_conf "/nonexistent/path/edge.conf" 2>/dev/null; then
    fail "missing file should return failure"
else
    pass "missing file returns failure"
fi

comment_only_conf="$TMP_DIR/comments.conf"
cat > "$comment_only_conf" <<'EOF'
# This is a comment
# Another comment

# Blank lines above
EOF
reset_edge_defaults
parse_edge_conf "$comment_only_conf"
assert_eq "comment-only conf keeps defaults" "$EDGE_CIPHER" "3"
assert_eq "comment-only conf no community" "$EDGE_COMMUNITY" ""

unknown_flags_conf="$TMP_DIR/unknown.conf"
cat > "$unknown_flags_conf" <<'EOF'
-c=mynet
-l=sn.test.com:7777
-a=static:10.0.0.5/24
--unknown-flag=something
-Z
-x=foo
EOF
reset_edge_defaults
parse_edge_conf "$unknown_flags_conf"
assert_eq "unknown flags: community parsed" "$EDGE_COMMUNITY" "mynet"
assert_eq "unknown flags: supernode parsed" "$EDGE_SUPERNODE" "sn.test.com:7777"
assert_eq "unknown flags: IP parsed" "$EDGE_IP" "10.0.0.5"

minimal_conf="$TMP_DIR/minimal.conf"
cat > "$minimal_conf" <<'EOF'
-c=net1
-l=sn:7777
-a=10.1.0.1
EOF
reset_edge_defaults
parse_edge_conf "$minimal_conf"
assert_eq "minimal: community" "$EDGE_COMMUNITY" "net1"
assert_eq "minimal: IP without static prefix" "$EDGE_IP" "10.1.0.1"
assert_eq "minimal: default CIDR" "$EDGE_CIDR" "24"
assert_eq "minimal: default key empty" "$EDGE_KEY" ""

multi_sn_conf="$TMP_DIR/multi_sn.conf"
cat > "$multi_sn_conf" <<'EOF'
-c=test
-l=sn1.test.com:7777
-l=sn2.test.com:7778
-l=sn3.test.com:7779
-a=static:10.0.0.1/24
EOF
reset_edge_defaults
parse_edge_conf "$multi_sn_conf"
assert_eq "multi SN: first preserved" "$EDGE_SUPERNODE" "sn1.test.com:7777"
assert_eq "multi SN: last extra becomes backup" "$EDGE_SUPERNODE2" "sn3.test.com:7779"

test_summary
