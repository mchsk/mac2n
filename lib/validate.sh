#!/usr/bin/env bash
# lib/validate.sh — All validation and conflict-detection functions
# Depends on: lib/core.sh

[[ -n "${_LIB_VALIDATE_LOADED:-}" ]] && return 0
[[ -n "${_LIB_CORE_LOADED:-}" ]] || { echo "lib/validate.sh: lib/core.sh must be loaded first" >&2; exit 1; }
_LIB_VALIDATE_LOADED=1

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

validate_instance_name() {
    local name=$1
    if [[ -z "$name" ]]; then
        echo "Instance name cannot be empty"
        return 1
    fi
    if (( ${#name} > 30 )); then
        echo "Instance name too long (max 30 chars, got ${#name})"
        return 1
    fi
    if ! [[ "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        echo "Must start with a letter and contain only letters, digits, hyphens, underscores"
        return 1
    fi
    local reserved
    for reserved in all supernode help status list create edit delete show \
                    start stop restart logs log tail migrate uninstall \
                    menu wizard configure setup new add modify update remove rm \
                    info inspect ls sn self-update upgrade; do
        if [[ "$name" == "$reserved" ]]; then
            echo "\"$name\" is a reserved name"
            return 1
        fi
    done
    return 0
}

validate_community() {
    local name=$1
    if [[ -z "$name" ]]; then
        echo "Community name cannot be empty"
        return 1
    fi
    if (( ${#name} > 19 )); then
        echo "Community name too long (max 19 chars, got ${#name})"
        return 1
    fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "Community name may only contain letters, digits, and underscores"
        return 1
    fi
    return 0
}

validate_ipv4() {
    local ip=$1
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Invalid IPv4 format"
        return 1
    fi
    local IFS='.'
    read -ra octets <<< "$ip"
    for o in "${octets[@]}"; do
        o=$((10#$o))
        if (( o > 255 )); then
            echo "Invalid IPv4 octet: $o"
            return 1
        fi
    done
    return 0
}

validate_private_ip() {
    local ip=$1
    local err
    err=$(validate_ipv4 "$ip") || { echo "$err"; return 1; }

    local IFS='.'
    read -ra raw <<< "$ip"
    local o0=$((10#${raw[0]})) o1=$((10#${raw[1]}))
    if (( o0 == 10 )); then return 0; fi
    if (( o0 == 172 && o1 >= 16 && o1 <= 31 )); then return 0; fi
    if (( o0 == 192 && o1 == 168 )); then return 0; fi

    echo "Not a private IP range (use 10.x, 172.16-31.x, or 192.168.x)"
    return 1
}

validate_port() {
    local port=$1 label=${2:-Port}
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$label must be a number"
        return 1
    fi
    if (( 10#$port < 1 || 10#$port > 65535 )); then
        echo "$label must be between 1 and 65535"
        return 1
    fi
    return 0
}

check_port_available() {
    local port=$1
    if lsof -iTCP:"$port" -sTCP:LISTEN -P -n &>/dev/null || \
       lsof -iUDP:"$port" -P -n &>/dev/null; then
        return 1
    fi
    return 0
}

validate_supernode_addr() {
    local addr=$1
    if [[ -z "$addr" ]]; then
        echo "Supernode address cannot be empty"
        return 1
    fi
    if ! [[ "$addr" =~ : ]]; then
        echo "Missing port — use host:port format (e.g. sn.example.com:7777)"
        return 1
    fi
    local host="${addr%:*}"
    local port="${addr##*:}"
    if [[ -z "$host" ]]; then
        echo "Missing hostname"
        return 1
    fi
    local perr
    perr=$(validate_port "$port" "Supernode port") || { echo "$perr"; return 1; }
    return 0
}

validate_cidr() {
    local cidr=$1
    if ! [[ "$cidr" =~ ^[0-9]+$ ]]; then
        echo "CIDR must be a number"
        return 1
    fi
    if (( 10#$cidr < 1 || 10#$cidr > 30 )); then
        echo "CIDR must be between 1 and 30"
        return 1
    fi
    return 0
}

validate_mtu() {
    local mtu=$1
    if ! [[ "$mtu" =~ ^[0-9]+$ ]]; then
        echo "MTU must be a number"
        return 1
    fi
    if (( 10#$mtu < 500 || 10#$mtu > 1500 )); then
        echo "MTU must be between 500 and 1500"
        return 1
    fi
    return 0
}

validate_mac() {
    local mac=$1
    if ! [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        echo "Invalid MAC format (use XX:XX:XX:XX:XX:XX)"
        return 1
    fi
    return 0
}

validate_route() {
    local route=$1
    if [[ -z "$route" ]]; then
        return 0
    fi
    if ! [[ "$route" =~ : ]]; then
        echo "Route must use CIDR:gateway format (e.g. 10.0.0.0/8:10.55.0.254)"
        return 1
    fi
    local cidr_part="${route%%:*}"
    local gw_part="${route#*:}"
    if [[ -z "$cidr_part" ]]; then
        echo "Missing network CIDR in route"
        return 1
    fi
    if ! [[ "$cidr_part" =~ / ]]; then
        echo "Network must include /prefix (e.g. 10.0.0.0/8)"
        return 1
    fi
    local net_ip="${cidr_part%/*}"
    local net_prefix="${cidr_part#*/}"
    local err
    if ! err=$(validate_ipv4 "$net_ip" 2>&1); then
        echo "Route network: $err"
        return 1
    fi
    if ! [[ "$net_prefix" =~ ^[0-9]+$ ]] || (( 10#$net_prefix < 0 || 10#$net_prefix > 32 )); then
        echo "Route prefix must be 0-32 (got $net_prefix)"
        return 1
    fi
    if [[ -z "$gw_part" ]]; then
        echo "Missing gateway IP in route"
        return 1
    fi
    if ! err=$(validate_ipv4 "$gw_part" 2>&1); then
        echo "Route gateway: $err"
        return 1
    fi
    return 0
}

check_key_strength() {
    local key=$1
    local len=${#key}
    if (( len == 0 )); then echo "empty"; return 1; fi
    if (( len < 8 )); then echo "weak"; return 1; fi
    if (( len < 12 )); then echo "fair"; return 0; fi
    local score=0
    [[ "$key" =~ [A-Z] ]] && score=$((score + 1))
    [[ "$key" =~ [a-z] ]] && score=$((score + 1))
    [[ "$key" =~ [0-9] ]] && score=$((score + 1))
    [[ "$key" =~ [^a-zA-Z0-9] ]] && score=$((score + 1))
    if (( len >= 16 && score >= 3 )); then echo "strong"
    elif (( len >= 12 && score >= 2 )); then echo "good"
    else echo "fair"
    fi
    return 0
}

ip_conflicts_with_interface() {
    local test_ip=$1
    while IFS= read -r line; do
        local iface_ip="${line%%/*}"
        if [[ "$iface_ip" == "$test_ip" ]]; then
            return 0
        fi
    done < <(ifconfig 2>/dev/null | grep 'inet ' | awk '{print $2}')
    return 1
}

check_ip_conflict_with_instances() {
    local check_ip=$1
    local exclude_name=${2:-}
    local name

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" == "$exclude_name" ]] && continue
        local conf
        conf="$(instance_config_path "$name")"
        [[ -f "$conf" ]] || continue
        local existing_ip
        existing_ip=$(grep '^-a=' "$conf" 2>/dev/null | head -1 | sed 's/^-a=//' | sed 's/^static://' | sed 's|/.*||') || true
        if [[ "${existing_ip:-}" == "$check_ip" ]]; then
            echo "$name"
            return
        fi
    done < <(list_instance_names)
}

check_mgmt_port_conflict() {
    local check_port=$1
    local exclude_name=${2:-}
    local name

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$name" == "$exclude_name" ]] && continue
        local conf
        conf="$(instance_config_path "$name")"
        [[ -f "$conf" ]] || continue
        local existing_port
        existing_port=$(grep '^-t=' "$conf" 2>/dev/null | head -1 | cut -d= -f2) || true
        if [[ "${existing_port:-}" == "$check_port" ]]; then
            echo "$name"
            return
        fi
    done < <(list_instance_names)
}
