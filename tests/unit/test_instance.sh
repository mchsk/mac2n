#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/instance.sh"
source "$SCRIPT_DIR/lib/service.sh"
source "$SCRIPT_DIR/tests/framework.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mac2n-test-instance.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

header "instance path helpers"

assert_eq "config_dir" "$(instance_config_dir "mytest")" "$INSTANCES_DIR/mytest"
assert_eq "config_path" "$(instance_config_path "mytest")" "$INSTANCES_DIR/mytest/edge.conf"
assert_eq "plist_label" "$(instance_plist_label "mytest")" "org.ntop.n2n-edge.mytest"
assert_eq "plist_path" "$(instance_plist_path "mytest")" "/Library/LaunchDaemons/org.ntop.n2n-edge.mytest.plist"
assert_eq "log_path" "$(instance_log_path "mytest")" "/var/log/n2n-edge-mytest.log"

header "instance_exists (non-existent)"

if instance_exists "nonexistent_test_abc"; then
    fail "nonexistent instance should not exist"
else
    pass "nonexistent instance returns false"
fi

header "list_instance_names"

ORIG_INSTANCES_DIR="$INSTANCES_DIR"
INSTANCES_DIR="$TMP_DIR/instances"

names=$(list_instance_names)
assert_eq "empty when no dir" "$names" ""

mkdir -p "$INSTANCES_DIR"
names=$(list_instance_names)
assert_eq "empty when dir exists but no instances" "$names" ""

mkdir -p "$INSTANCES_DIR/alpha"
echo "-c=net1" > "$INSTANCES_DIR/alpha/edge.conf"
mkdir -p "$INSTANCES_DIR/beta"
echo "-c=net2" > "$INSTANCES_DIR/beta/edge.conf"
mkdir -p "$INSTANCES_DIR/gamma"

names=$(list_instance_names | sort)
expected=$(printf 'alpha\nbeta')
assert_eq "lists alpha and beta (gamma has no conf)" "$names" "$expected"

header "instance_exists with temp instances"

if instance_exists "alpha"; then
    pass "alpha exists"
else
    fail "alpha should exist"
fi

if instance_exists "gamma"; then
    fail "gamma should not exist (no edge.conf)"
else
    pass "gamma without edge.conf does not exist"
fi

header "instance_status_plain"

status=$(instance_status_plain "alpha")
assert_eq "config-only status for alpha" "$status" "config-only"

header "next_available_mgmt_port"

cat > "$INSTANCES_DIR/alpha/edge.conf" <<'EOF'
-c=net1
-a=static:10.0.0.1/24
-t=5644
EOF
cat > "$INSTANCES_DIR/beta/edge.conf" <<'EOF'
-c=net2
-a=static:10.0.0.2/24
-t=5646
EOF

port=$(next_available_mgmt_port)
if [[ "$port" != "5644" ]] && [[ "$port" != "5645" ]] && [[ "$port" != "5646" ]]; then
    pass "next port avoids 5644, 5645, 5646 (got $port)"
else
    fail "next port should avoid used ports (got $port)"
fi

INSTANCES_DIR="$ORIG_INSTANCES_DIR"

test_summary
