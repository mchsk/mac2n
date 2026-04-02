#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/instance.sh"
source "$SCRIPT_DIR/tests/framework.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac2n-test-validate.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

header "validate_instance_name"

assert_exit_success "accepts valid name 'home'" validate_instance_name "home"
assert_exit_success "accepts name with digits 'vpn2'" validate_instance_name "vpn2"
assert_exit_success "accepts hyphens 'my-vpn'" validate_instance_name "my-vpn"
assert_exit_success "accepts underscores 'my_vpn'" validate_instance_name "my_vpn"
assert_exit_fail "rejects empty name" validate_instance_name ""
assert_exit_fail "rejects too-long name" validate_instance_name "$(printf 'a%.0s' $(seq 1 31))"
assert_exit_fail "rejects starting with digit" validate_instance_name "1bad"
assert_exit_fail "rejects starting with hyphen" validate_instance_name "-bad"
assert_exit_fail "rejects reserved word 'help'" validate_instance_name "help"
assert_exit_fail "rejects reserved word 'status'" validate_instance_name "status"
assert_exit_fail "rejects reserved word 'all'" validate_instance_name "all"

header "validate_community"

assert_exit_success "accepts valid community 'home'" validate_community "home"
assert_exit_success "accepts 19-char community" validate_community "$(printf 'a%.0s' $(seq 1 19))"
assert_exit_fail "rejects empty community" validate_community ""
assert_exit_fail "rejects 20-char community" validate_community "$(printf 'a%.0s' $(seq 1 20))"
assert_exit_fail "rejects spaces" validate_community "my vpn"
assert_exit_fail "rejects special chars" validate_community "my@vpn"

header "validate_ipv4"

assert_exit_success "accepts 10.0.0.1" validate_ipv4 "10.0.0.1"
assert_exit_success "accepts 255.255.255.255" validate_ipv4 "255.255.255.255"
assert_exit_success "accepts 0.0.0.0" validate_ipv4 "0.0.0.0"
assert_exit_fail "rejects empty" validate_ipv4 ""
assert_exit_fail "rejects 256.0.0.1" validate_ipv4 "256.0.0.1"
assert_exit_fail "rejects 1.2.3" validate_ipv4 "1.2.3"
assert_exit_fail "rejects letters" validate_ipv4 "a.b.c.d"

header "validate_private_ip"

assert_exit_success "accepts 10.0.0.1" validate_private_ip "10.0.0.1"
assert_exit_success "accepts 172.16.0.1" validate_private_ip "172.16.0.1"
assert_exit_success "accepts 172.31.255.255" validate_private_ip "172.31.255.255"
assert_exit_success "accepts 192.168.1.1" validate_private_ip "192.168.1.1"
assert_exit_fail "rejects 8.8.8.8" validate_private_ip "8.8.8.8"
assert_exit_fail "rejects 172.15.0.1" validate_private_ip "172.15.0.1"
assert_exit_fail "rejects 172.32.0.1" validate_private_ip "172.32.0.1"

header "validate_port"

assert_exit_success "accepts 1" validate_port "1"
assert_exit_success "accepts 65535" validate_port "65535"
assert_exit_success "accepts 7777" validate_port "7777"
assert_exit_fail "rejects 0" validate_port "0"
assert_exit_fail "rejects 65536" validate_port "65536"
assert_exit_fail "rejects letters" validate_port "abc"

header "validate_supernode_addr"

assert_exit_success "accepts host:port" validate_supernode_addr "sn.example.com:7777"
assert_exit_success "accepts IP:port" validate_supernode_addr "1.2.3.4:7777"
assert_exit_fail "rejects missing port" validate_supernode_addr "sn.example.com"
assert_exit_fail "rejects empty" validate_supernode_addr ""
assert_exit_fail "rejects :only" validate_supernode_addr ":7777"

header "validate_cidr"

assert_exit_success "accepts 1" validate_cidr "1"
assert_exit_success "accepts 24" validate_cidr "24"
assert_exit_success "accepts 30" validate_cidr "30"
assert_exit_fail "rejects 0" validate_cidr "0"
assert_exit_fail "rejects 31" validate_cidr "31"

header "validate_mtu"

assert_exit_success "accepts 500" validate_mtu "500"
assert_exit_success "accepts 1500" validate_mtu "1500"
assert_exit_success "accepts 1290" validate_mtu "1290"
assert_exit_fail "rejects 499" validate_mtu "499"
assert_exit_fail "rejects 1501" validate_mtu "1501"

header "validate_mac"

assert_exit_success "accepts valid MAC" validate_mac "aa:bb:cc:dd:ee:ff"
assert_exit_success "accepts uppercase MAC" validate_mac "AA:BB:CC:DD:EE:FF"
assert_exit_fail "rejects short MAC" validate_mac "aa:bb:cc:dd:ee"
assert_exit_fail "rejects no colons" validate_mac "aabbccddeeff"

header "check_key_strength"

assert_eq "empty key returns 'empty'" "$(check_key_strength "")" "empty"
assert_eq "short key returns 'weak'" "$(check_key_strength "abc")" "weak"
assert_eq "8-char key returns 'fair'" "$(check_key_strength "abcdefgh")" "fair"
assert_eq "16-char mixed returns 'strong'" "$(check_key_strength "Abc123!@defgHIJK")" "strong"

header "validate_route"

assert_exit_success "accepts valid route" validate_route "10.0.0.0/8:10.55.0.254"
assert_exit_success "accepts default route" validate_route "0.0.0.0/0:10.55.0.1"
assert_exit_success "accepts /32 host route" validate_route "192.168.1.1/32:10.0.0.1"
assert_exit_success "accepts empty (optional)" validate_route ""
assert_exit_fail "rejects missing colon" validate_route "10.0.0.0/8"
assert_exit_fail "rejects missing prefix" validate_route "10.0.0.0:10.55.0.1"
assert_exit_fail "rejects missing gateway" validate_route "10.0.0.0/8:"
assert_exit_fail "rejects invalid network IP" validate_route "999.0.0.0/8:10.0.0.1"
assert_exit_fail "rejects invalid gateway IP" validate_route "10.0.0.0/8:999.0.0.1"
assert_exit_fail "rejects prefix > 32" validate_route "10.0.0.0/33:10.0.0.1"
assert_exit_fail "rejects non-numeric prefix" validate_route "10.0.0.0/abc:10.0.0.1"
assert_exit_fail "rejects missing network" validate_route ":10.0.0.1"

header "xml_escape"

assert_eq "escapes ampersand" "$(xml_escape '&')" '&amp;'
assert_eq "escapes less-than" "$(xml_escape '<')" '&lt;'
assert_eq "escapes greater-than" "$(xml_escape '>')" '&gt;'
assert_eq "escapes double-quote" "$(xml_escape '"')" '&quot;'
assert_eq "passes through plain text" "$(xml_escape 'hello')" 'hello'

header "check_ip_conflict_with_instances"

ORIG_INSTANCES_DIR="$INSTANCES_DIR"
INSTANCES_DIR="$TMP_DIR/instances"
mkdir -p "$INSTANCES_DIR/inst_a"
cat > "$INSTANCES_DIR/inst_a/edge.conf" <<'EOF'
-c=net1
-a=static:10.0.0.1/24
-t=5644
EOF
mkdir -p "$INSTANCES_DIR/inst_b"
cat > "$INSTANCES_DIR/inst_b/edge.conf" <<'EOF'
-c=net2
-a=static:10.0.0.2/24
-t=5646
EOF

conflict=$(check_ip_conflict_with_instances "10.0.0.1" "")
assert_eq "detects IP conflict" "$conflict" "inst_a"

conflict=$(check_ip_conflict_with_instances "10.0.0.1" "inst_a")
assert_eq "no conflict when excluding self" "$conflict" ""

conflict=$(check_ip_conflict_with_instances "10.0.0.99" "")
assert_eq "no conflict for unused IP" "$conflict" ""

header "check_mgmt_port_conflict"

conflict=$(check_mgmt_port_conflict "5644" "")
assert_eq "detects port conflict" "$conflict" "inst_a"

conflict=$(check_mgmt_port_conflict "5644" "inst_a")
assert_eq "no port conflict when excluding self" "$conflict" ""

conflict=$(check_mgmt_port_conflict "9999" "")
assert_eq "no conflict for unused port" "$conflict" ""

INSTANCES_DIR="$ORIG_INSTANCES_DIR"

test_summary
