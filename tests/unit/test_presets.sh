#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/instance.sh"
source "$SCRIPT_DIR/lib/service.sh"
source "$SCRIPT_DIR/lib/edge_model.sh"
source "$SCRIPT_DIR/lib/presets.sh"
source "$SCRIPT_DIR/tests/framework.sh"

header "Preset 1: Home VPN"

reset_edge_defaults
USECASE=1
apply_usecase_defaults
assert_eq "home community" "$EDGE_COMMUNITY" "home"
assert_eq "home cipher AES" "$EDGE_CIPHER" "3"
assert_eq "home IP" "$EDGE_IP" "10.88.0.1"
assert_eq "home CIDR" "$EDGE_CIDR" "24"
assert_eq "home routing off" "$EDGE_ROUTING" "n"
assert_eq "home multicast off" "$EDGE_MULTICAST" "n"
assert_eq "home MTU" "$EDGE_MTU" "1290"
assert_eq "home no compression" "$EDGE_COMPRESSION" ""

header "Preset 2: Remote Access"

reset_edge_defaults
USECASE=2
apply_usecase_defaults
assert_eq "remote community" "$EDGE_COMMUNITY" "remote"
assert_eq "remote cipher ChaCha20" "$EDGE_CIPHER" "4"
assert_eq "remote IP" "$EDGE_IP" "10.90.0.1"
assert_eq "remote routing on" "$EDGE_ROUTING" "y"
assert_eq "remote multicast off" "$EDGE_MULTICAST" "n"

header "Preset 3: Site-to-Site"

reset_edge_defaults
USECASE=3
apply_usecase_defaults
assert_eq "site2site community" "$EDGE_COMMUNITY" "site2site"
assert_eq "site2site cipher AES" "$EDGE_CIPHER" "3"
assert_eq "site2site IP" "$EDGE_IP" "10.100.0.1"
assert_eq "site2site routing on" "$EDGE_ROUTING" "y"
assert_eq "site2site multicast on" "$EDGE_MULTICAST" "y"

header "Preset 4: Gaming / LAN"

reset_edge_defaults
USECASE=4
apply_usecase_defaults
assert_eq "gaming community" "$EDGE_COMMUNITY" "lan"
assert_eq "gaming cipher NONE" "$EDGE_CIPHER" "1"
assert_eq "gaming IP" "$EDGE_IP" "10.77.0.1"
assert_eq "gaming MTU high" "$EDGE_MTU" "1400"
assert_eq "gaming multicast on" "$EDGE_MULTICAST" "y"
assert_eq "gaming SN select RTT" "$EDGE_SN_SELECT" "rtt"
assert_eq "gaming routing off" "$EDGE_ROUTING" "n"

header "Preset 5: IoT Mesh"

reset_edge_defaults
USECASE=5
apply_usecase_defaults
assert_eq "iot community" "$EDGE_COMMUNITY" "iot"
assert_eq "iot cipher Speck" "$EDGE_CIPHER" "5"
assert_eq "iot IP" "$EDGE_IP" "10.66.0.1"
assert_eq "iot CIDR /16" "$EDGE_CIDR" "16"
assert_eq "iot MTU low" "$EDGE_MTU" "1000"
assert_eq "iot routing on" "$EDGE_ROUTING" "y"
assert_eq "iot compression LZO" "$EDGE_COMPRESSION" "1"

header "Preset 6: Custom"

reset_edge_defaults
USECASE=6
apply_usecase_defaults
assert_eq "custom community empty" "$EDGE_COMMUNITY" ""
assert_eq "custom key empty" "$EDGE_KEY" ""
assert_eq "custom cipher default AES" "$EDGE_CIPHER" "3"
assert_eq "custom IP empty" "$EDGE_IP" ""
assert_eq "custom routing off" "$EDGE_ROUTING" "n"

test_summary
