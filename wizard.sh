#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# mac2n — N2N VPN for macOS
# Multi-instance edge management with full CRUD, supernode support,
# and LaunchDaemon integration (native utun interface)
# ─────────────────────────────────────────────────────────────────────────────

_resolve_script_dir() {
    local src="$0"
    while [[ -L "$src" ]]; do
        local dir
        dir="$(cd "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_dir)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.0.0-dev")

CONFIG_DIR="$HOME/.config/n2n"
INSTANCES_DIR="$CONFIG_DIR/instances"
PLIST_DIR="/Library/LaunchDaemons"
PLIST_PREFIX="org.ntop.n2n-edge"
SN_PLIST_LABEL="org.ntop.n2n-supernode"
LOGROTATE_LABEL="org.ntop.n2n-logrotate"
LOG_DIR="/var/log"
EDGE_BIN="${EDGE_BIN:-}"
SUPERNODE_BIN="${SUPERNODE_BIN:-}"

# ── Colors & Symbols ────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    BOLD='\033[1m'       DIM='\033[2m'        RESET='\033[0m'
    RED='\033[0;31m'     GREEN='\033[0;32m'   YELLOW='\033[0;33m'
    CYAN='\033[0;36m'    WHITE='\033[1;37m'   GRAY='\033[0;90m'
else
    BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW=''
    CYAN='' WHITE='' GRAY=''
fi

_CLEANUP_FILES=()
_cleanup() {
    (( ${#_CLEANUP_FILES[@]} > 0 )) || return 0
    local f
    for f in "${_CLEANUP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap _cleanup EXIT

SYM_OK="${GREEN}✓${RESET}"
SYM_FAIL="${RED}✗${RESET}"
SYM_WARN="${YELLOW}⚠${RESET}"
SYM_ARROW="${CYAN}▸${RESET}"
SYM_DOT="${GRAY}·${RESET}"
SYM_LOCK="${YELLOW}🔒${RESET}"

# ── UI Helpers ───────────────────────────────────────────────────────────────

print_header() {
    local width=60
    echo ""
    printf "${CYAN}"
    printf '  ╭'; printf '─%.0s' $(seq 1 $width); printf '╮\n'
    local pad_l=$(( (width - ${#1}) / 2 ))
    local pad_r=$(( width - ${#1} - pad_l ))
    printf '  │%*s%s%*s│\n' "$pad_l" "" "$1" "$pad_r" ""
    if [[ -n "${2:-}" ]]; then
        pad_l=$(( (width - ${#2}) / 2 ))
        pad_r=$(( width - ${#2} - pad_l ))
        printf '  │%*s%s%*s│\n' "$pad_l" "" "$2" "$pad_r" ""
    fi
    printf '  ╰'; printf '─%.0s' $(seq 1 $width); printf '╯\n'
    printf "${RESET}"
    echo ""
}

print_section() {
    echo ""
    printf "  ${WHITE}%s${RESET}\n" "$1"
    printf "  ${GRAY}"
    printf '─%.0s' $(seq 1 52)
    printf "${RESET}\n"
}

print_status() {
    local symbol=$1 msg=$2
    printf "  %b %b\n" "$symbol" "$msg"
}

print_info() {
    printf "  ${GRAY}%s${RESET}\n" "$1"
}

print_box() {
    local title=$1
    shift
    local width=56
    local content_width=$((width - 1))

    for line in "$@"; do
        if (( ${#line} + 2 > width )); then
            width=$((${#line} + 3))
            content_width=$((width - 1))
        fi
    done

    local border_fill=$((width - ${#title} - 3))
    if (( border_fill < 1 )); then border_fill=1; fi

    echo ""
    printf "  ${CYAN}┌─ %s " "$title"
    printf '─%.0s' $(seq 1 $border_fill)
    printf "┐${RESET}\n"
    for line in "$@"; do
        printf "  ${CYAN}│${RESET} %-*s ${CYAN}│${RESET}\n" "$content_width" "$line"
    done
    printf "  ${CYAN}└"
    printf '─%.0s' $(seq 1 $((width + 1)))
    printf "┘${RESET}\n"
}

_STDIN_EOF=false

ask() {
    local prompt=$1 default=${2:-} var_name=$3
    local input
    if [[ -n "$default" ]]; then
        printf "  ${SYM_ARROW} ${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$prompt" "$default"
    else
        printf "  ${SYM_ARROW} ${BOLD}%s${RESET}: " "$prompt"
    fi
    if ! read -r input; then
        _STDIN_EOF=true
        input="$default"
    fi
    input="${input:-$default}"
    printf -v "$var_name" '%s' "$input"
}

ask_password() {
    local prompt=$1 var_name=$2
    local input
    printf "  ${SYM_LOCK} ${BOLD}%s${RESET}: " "$prompt"
    if ! read -rs input; then
        _STDIN_EOF=true
        input=""
    fi
    echo ""
    printf -v "$var_name" '%s' "$input"
}

ask_yesno() {
    local prompt=$1 default=${2:-y}
    local hint input
    if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    printf "  ${SYM_ARROW} ${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$prompt" "$hint"
    if ! read -r input; then
        input="$default"
    fi
    input="${input:-$default}"
    [[ "$input" =~ ^[Yy] ]]
}

ask_choice() {
    local prompt=$1 var_name=$2
    shift 2
    local options=("$@")
    local i=1

    echo ""
    for opt in "${options[@]}"; do
        printf "    ${WHITE}%d)${RESET} %s\n" "$i" "$opt"
        i=$((i + 1))
    done
    echo ""

    local choice
    while true; do
        printf "  ${SYM_ARROW} ${BOLD}%s${RESET} ${DIM}[1-%d]${RESET}: " "$prompt" "${#options[@]}"
        if ! read -r choice; then
            echo ""
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            printf -v "$var_name" '%s' "$choice"
            return
        fi
        printf "  ${RED}Invalid choice. Enter a number 1-%d.${RESET}\n" "${#options[@]}"
    done
}

# ── Validation Functions ─────────────────────────────────────────────────────

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

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
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

# ── Instance Path Helpers ────────────────────────────────────────────────────

instance_config_dir() { echo "$INSTANCES_DIR/$1"; }
instance_config_path() { echo "$INSTANCES_DIR/$1/edge.conf"; }
instance_plist_label() { echo "${PLIST_PREFIX}.$1"; }
instance_plist_path() { echo "${PLIST_DIR}/${PLIST_PREFIX}.$1.plist"; }
instance_log_path() { echo "${LOG_DIR}/n2n-edge-$1.log"; }

# ── Instance Discovery ──────────────────────────────────────────────────────

list_instance_names() {
    if [[ ! -d "$INSTANCES_DIR" ]]; then
        return
    fi
    local dir
    for dir in "$INSTANCES_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"
        if [[ -f "$dir/edge.conf" ]]; then
            printf '%s\n' "$name"
        fi
    done
}

instance_exists() {
    [[ -f "$(instance_config_path "$1")" ]]
}

instance_plist_installed() {
    [[ -f "$(instance_plist_path "$1")" ]]
}

launchd_label_loaded() {
    local label="$1"
    # User domain (current user's agents)
    launchctl list "$label" &>/dev/null && return 0
    # System domain (LaunchDaemons run as root) — non-interactive sudo
    sudo -n launchctl list "$label" &>/dev/null && return 0
    return 1
}

instance_is_loaded() {
    launchd_label_loaded "$(instance_plist_label "$1")"
}

_launchctl_pid_from_label() {
    local label="$1" output pid
    if output=$(launchctl list "$label" 2>/dev/null); then
        pid=$(echo "$output" | awk '/"PID"/ { gsub(/[^0-9]/, "", $NF); print $NF }')
        if [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
            echo "$pid"
            return 0
        fi
    fi
    if output=$(sudo -n launchctl list "$label" 2>/dev/null); then
        pid=$(echo "$output" | awk '/"PID"/ { gsub(/[^0-9]/, "", $NF); print $NF }')
        if [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
            echo "$pid"
            return 0
        fi
    fi
    return 1
}

instance_pid() {
    local label
    label="$(instance_plist_label "$1")"
    _launchctl_pid_from_label "$label" || true
}

instance_is_running() {
    local pid
    pid=$(instance_pid "$1")
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

instance_status_plain() {
    if instance_is_running "$1"; then echo "running"
    elif instance_is_loaded "$1"; then echo "loaded"
    elif instance_plist_installed "$1"; then echo "installed"
    else echo "config-only"
    fi
}

# ── System Detection ────────────────────────────────────────────────────────

detect_binaries() {
    if [[ -z "$EDGE_BIN" ]]; then
        EDGE_BIN=$(command -v edge 2>/dev/null || echo "")
    fi
    if [[ -z "$EDGE_BIN" ]] && [[ -x /usr/local/sbin/edge ]]; then
        EDGE_BIN="/usr/local/sbin/edge"
    fi
    if [[ -z "$EDGE_BIN" ]] && [[ -x /usr/local/bin/edge ]]; then
        EDGE_BIN="/usr/local/bin/edge"
    fi
    if [[ -z "$SUPERNODE_BIN" ]]; then
        SUPERNODE_BIN=$(command -v supernode 2>/dev/null || echo "")
    fi
    if [[ -z "$SUPERNODE_BIN" ]] && [[ -x /usr/local/sbin/supernode ]]; then
        SUPERNODE_BIN="/usr/local/sbin/supernode"
    fi
    if [[ -z "$SUPERNODE_BIN" ]] && [[ -x /usr/local/bin/supernode ]]; then
        SUPERNODE_BIN="/usr/local/bin/supernode"
    fi
}

require_edge_binary() {
    if [[ -z "$EDGE_BIN" ]]; then
        print_status "$SYM_FAIL" "edge binary not found. Run: cd ~/.mac2n && ./build.sh all"
        return 1
    fi
}

ensure_sudo() {
    if ! sudo -n true 2>/dev/null; then
        sudo -v
    fi
}

# ── Management Port Allocation ───────────────────────────────────────────────

next_available_mgmt_port() {
    local port=5644
    local used=()
    local conf

    for conf in "$INSTANCES_DIR"/*/edge.conf; do
        [[ -f "$conf" ]] || continue
        local p
        p=$(grep '^-t=' "$conf" 2>/dev/null | head -1 | cut -d= -f2) || true
        [[ -n "${p:-}" ]] && used+=("$p")
    done

    # Supernode default management port
    used+=(5645)
    if [[ -f "$CONFIG_DIR/supernode.conf" ]]; then
        local sp
        sp=$(grep '^-t=' "$CONFIG_DIR/supernode.conf" 2>/dev/null | head -1 | cut -d= -f2) || true
        [[ -n "${sp:-}" ]] && used+=("$sp")
    fi

    while (( port <= 65535 )); do
        local collision=false
        local u
        for u in "${used[@]}"; do
            if [[ "$u" == "$port" ]]; then
                collision=true
                break
            fi
        done
        if ! $collision && check_port_available "$port"; then
            echo "$port"
            return
        fi
        port=$((port + 1))
    done

    echo "5644"
}

# ── Config Parser & Generator ────────────────────────────────────────────────

EDGE_COMMUNITY=""
EDGE_KEY=""
EDGE_CIPHER="3"
EDGE_IP=""
EDGE_CIDR="24"
EDGE_SUPERNODE=""
EDGE_SUPERNODE2=""
EDGE_MTU="1290"
EDGE_ROUTING="n"
EDGE_MULTICAST="n"
EDGE_COMPRESSION=""
EDGE_MAC=""
EDGE_LOCAL_PORT="0"
EDGE_MGMT_PORT="5644"
EDGE_SN_SELECT=""
EDGE_DESCRIPTION=""
EDGE_VERBOSITY="0"
EDGE_ROUTES=""

reset_edge_defaults() {
    EDGE_COMMUNITY=""
    EDGE_KEY=""
    EDGE_CIPHER="3"
    EDGE_IP=""
    EDGE_CIDR="24"
    EDGE_SUPERNODE=""
    EDGE_SUPERNODE2=""
    EDGE_MTU="1290"
    EDGE_ROUTING="n"
    EDGE_MULTICAST="n"
    EDGE_COMPRESSION=""
    EDGE_MAC=""
    EDGE_LOCAL_PORT="0"
    EDGE_MGMT_PORT="5644"
    EDGE_SN_SELECT=""
    EDGE_DESCRIPTION=""
    EDGE_VERBOSITY="0"
    EDGE_ROUTES=""
}

parse_edge_conf() {
    local conf_path="$1"
    reset_edge_defaults

    if [[ ! -f "$conf_path" ]]; then
        return 1
    fi

    local sn_count=0
    while IFS= read -r line; do
        [[ "$line" =~ ^#  ]] && continue
        [[ -z "$line" ]] && continue

        case "$line" in
            -c=*)
                EDGE_COMMUNITY="${line#-c=}" ;;
            -l=*)
                sn_count=$((sn_count + 1))
                if (( sn_count == 1 )); then
                    EDGE_SUPERNODE="${line#-l=}"
                else
                    EDGE_SUPERNODE2="${line#-l=}"
                fi
                ;;
            -a=static:*)
                local addr="${line#-a=static:}"
                EDGE_IP="${addr%/*}"
                if [[ "$addr" == */* ]]; then
                    EDGE_CIDR="${addr#*/}"
                fi
                ;;
            -a=*)
                local addr="${line#-a=}"
                EDGE_IP="${addr%/*}"
                if [[ "$addr" == */* ]]; then
                    EDGE_CIDR="${addr#*/}"
                fi
                ;;
            -k=*) EDGE_KEY="${line#-k=}" ;;
            -A1)  EDGE_CIPHER="1" ;;
            -A2)  EDGE_CIPHER="2" ;;
            -A3)  EDGE_CIPHER="3" ;;
            -A4)  EDGE_CIPHER="4" ;;
            -A5)  EDGE_CIPHER="5" ;;
            -A*)  EDGE_CIPHER="${line#-A}" ;;
            -M=*) EDGE_MTU="${line#-M=}" ;;
            -r)   EDGE_ROUTING="y" ;;
            -E)   EDGE_MULTICAST="y" ;;
            -z1)  EDGE_COMPRESSION="1" ;;
            -z2)  EDGE_COMPRESSION="2" ;;
            -z*)  EDGE_COMPRESSION="${line#-z}" ;;
            -m=*) EDGE_MAC="${line#-m=}" ;;
            -p=*) EDGE_LOCAL_PORT="${line#-p=}" ;;
            -t=*) EDGE_MGMT_PORT="${line#-t=}" ;;
            --select-rtt) EDGE_SN_SELECT="rtt" ;;
            --select-mac) EDGE_SN_SELECT="mac" ;;
            -I=*) EDGE_DESCRIPTION="${line#-I=}" ;;
            -n=*) EDGE_ROUTES="${line#-n=}" ;;
            -v)   EDGE_VERBOSITY=$((EDGE_VERBOSITY + 1)) ;;
            -H)   ;; # legacy header encryption flag — ignored
            -f)   ;; # foreground flag — always added
        esac
    done < "$conf_path"
}

generate_edge_conf() {
    local conf_path="$1"
    local instance_name="${2:-}"
    local lines=()

    lines+=("# N2N Edge Configuration")
    if [[ -n "$instance_name" ]]; then
        lines+=("# Instance: ${instance_name}")
    fi
    lines+=("# Generated on $(date '+%Y-%m-%d %H:%M:%S')")
    lines+=("")
    lines+=("-c=${EDGE_COMMUNITY}")
    lines+=("-l=${EDGE_SUPERNODE}")
    [[ -n "$EDGE_SUPERNODE2" ]] && lines+=("-l=${EDGE_SUPERNODE2}")
    lines+=("-a=static:${EDGE_IP}/${EDGE_CIDR}")
    [[ -n "$EDGE_KEY" ]] && lines+=("-k=${EDGE_KEY}")
    [[ "$EDGE_CIPHER" != "3" ]] && lines+=("-A${EDGE_CIPHER}")
    [[ "$EDGE_MTU" != "1290" ]] && lines+=("-M=${EDGE_MTU}")
    [[ "$EDGE_ROUTING" == "y" ]] && lines+=("-r")
    [[ "$EDGE_MULTICAST" == "y" ]] && lines+=("-E")
    [[ -n "${EDGE_COMPRESSION:-}" ]] && lines+=("-z${EDGE_COMPRESSION}")
    [[ -n "$EDGE_MAC" ]] && lines+=("-m=${EDGE_MAC}")
    [[ "$EDGE_LOCAL_PORT" != "0" ]] && [[ -n "$EDGE_LOCAL_PORT" ]] && lines+=("-p=${EDGE_LOCAL_PORT}")
    lines+=("-t=${EDGE_MGMT_PORT}")
    [[ "$EDGE_SN_SELECT" == "rtt" ]] && lines+=("--select-rtt")
    [[ "$EDGE_SN_SELECT" == "mac" ]] && lines+=("--select-mac")
    [[ -n "$EDGE_DESCRIPTION" ]] && lines+=("-I=${EDGE_DESCRIPTION}")
    [[ -n "$EDGE_ROUTES" ]] && lines+=("-n=${EDGE_ROUTES}")
    local i
    for (( i=0; i<EDGE_VERBOSITY; i++ )); do lines+=("-v"); done
    lines+=("-f")

    printf '%s\n' "${lines[@]}" > "$conf_path"
}

generate_edge_plist() {
    local plist_path="$1"
    local instance_name="$2"
    local label
    label="$(instance_plist_label "$instance_name")"
    local log_path
    log_path="$(instance_log_path "$instance_name")"

    local x_community x_supernode x_supernode2 x_key x_description x_routes
    x_community=$(xml_escape "$EDGE_COMMUNITY")
    x_supernode=$(xml_escape "$EDGE_SUPERNODE")
    x_supernode2=$(xml_escape "${EDGE_SUPERNODE2:-}")
    x_key=$(xml_escape "${EDGE_KEY:-}")
    x_description=$(xml_escape "${EDGE_DESCRIPTION:-}")
    x_routes=$(xml_escape "${EDGE_ROUTES:-}")

    local args=""
    args+="        <string>${EDGE_BIN}</string>\n"
    args+="        <string>-c</string>\n        <string>${x_community}</string>\n"
    args+="        <string>-l</string>\n        <string>${x_supernode}</string>\n"
    if [[ -n "$EDGE_SUPERNODE2" ]]; then
        args+="        <string>-l</string>\n        <string>${x_supernode2}</string>\n"
    fi
    args+="        <string>-a</string>\n        <string>static:${EDGE_IP}/${EDGE_CIDR}</string>\n"
    if [[ -n "$EDGE_KEY" ]]; then
        args+="        <string>-k</string>\n        <string>${x_key}</string>\n"
    fi
    [[ "$EDGE_CIPHER" != "3" ]] && args+="        <string>-A${EDGE_CIPHER}</string>\n"
    [[ "$EDGE_MTU" != "1290" ]] && args+="        <string>-M</string>\n        <string>${EDGE_MTU}</string>\n"
    [[ "$EDGE_ROUTING" == "y" ]] && args+="        <string>-r</string>\n"
    [[ "$EDGE_MULTICAST" == "y" ]] && args+="        <string>-E</string>\n"
    [[ -n "${EDGE_COMPRESSION:-}" ]] && args+="        <string>-z${EDGE_COMPRESSION}</string>\n"
    [[ -n "$EDGE_MAC" ]] && args+="        <string>-m</string>\n        <string>${EDGE_MAC}</string>\n"
    [[ "$EDGE_LOCAL_PORT" != "0" ]] && [[ -n "$EDGE_LOCAL_PORT" ]] && args+="        <string>-p</string>\n        <string>${EDGE_LOCAL_PORT}</string>\n"
    args+="        <string>-t</string>\n        <string>${EDGE_MGMT_PORT}</string>\n"
    [[ "$EDGE_SN_SELECT" == "rtt" ]] && args+="        <string>--select-rtt</string>\n"
    [[ "$EDGE_SN_SELECT" == "mac" ]] && args+="        <string>--select-mac</string>\n"
    [[ -n "$EDGE_DESCRIPTION" ]] && args+="        <string>-I</string>\n        <string>${x_description}</string>\n"
    [[ -n "$EDGE_ROUTES" ]] && args+="        <string>-n</string>\n        <string>${x_routes}</string>\n"
    local i
    for (( i=0; i<EDGE_VERBOSITY; i++ )); do args+="        <string>-v</string>\n"; done
    args+="        <string>-f</string>\n"

    cat > "$plist_path" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>

    <key>ProgramArguments</key>
    <array>
$(printf '%b' "$args" | sed '/^$/d')
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ProcessType</key>
    <string>Background</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>ExitTimeOut</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>${log_path}</string>

    <key>StandardErrorPath</key>
    <string>${log_path}</string>
</dict>
</plist>
PLISTEOF
}

# ── Display Helpers ──────────────────────────────────────────────────────────

cipher_name() {
    case $1 in
        1) echo "None (no encryption)" ;;
        2) echo "Twofish" ;;
        3) echo "AES-256-CBC" ;;
        4) echo "ChaCha20" ;;
        5) echo "Speck-CTR" ;;
        *) echo "Unknown ($1)" ;;
    esac
}

compression_name() {
    case ${1:-0} in
        1) echo "LZO1X" ;;
        2) echo "ZSTD" ;;
        *) echo "None" ;;
    esac
}

build_edge_display_cmd() {
    local cmd="sudo ${EDGE_BIN}"
    cmd+=" -c ${EDGE_COMMUNITY}"
    cmd+=" -l ${EDGE_SUPERNODE}"
    [[ -n "$EDGE_SUPERNODE2" ]] && cmd+=" -l ${EDGE_SUPERNODE2}"
    cmd+=" -a static:${EDGE_IP}/${EDGE_CIDR}"
    [[ -n "$EDGE_KEY" ]] && cmd+=" -k '***'"
    [[ "$EDGE_CIPHER" != "3" ]] && cmd+=" -A${EDGE_CIPHER}"
    [[ "$EDGE_MTU" != "1290" ]] && cmd+=" -M ${EDGE_MTU}"
    [[ "$EDGE_ROUTING" == "y" ]] && cmd+=" -r"
    [[ "$EDGE_MULTICAST" == "y" ]] && cmd+=" -E"
    [[ -n "${EDGE_COMPRESSION:-}" ]] && cmd+=" -z${EDGE_COMPRESSION}"
    [[ -n "$EDGE_MAC" ]] && cmd+=" -m ${EDGE_MAC}"
    [[ "$EDGE_LOCAL_PORT" != "0" ]] && [[ -n "$EDGE_LOCAL_PORT" ]] && cmd+=" -p ${EDGE_LOCAL_PORT}"
    cmd+=" -t ${EDGE_MGMT_PORT}"
    [[ "$EDGE_SN_SELECT" == "rtt" ]] && cmd+=" --select-rtt"
    [[ "$EDGE_SN_SELECT" == "mac" ]] && cmd+=" --select-mac"
    [[ -n "$EDGE_DESCRIPTION" ]] && cmd+=" -I '${EDGE_DESCRIPTION}'"
    [[ -n "$EDGE_ROUTES" ]] && cmd+=" -n ${EDGE_ROUTES}"
    local i
    for (( i=0; i<EDGE_VERBOSITY; i++ )); do cmd+=" -v"; done
    cmd+=" -f"
    echo "$cmd"
}

review_edge_config() {
    local instance_name="${1:-}"

    local enc_info
    if [[ "$EDGE_CIPHER" == "1" ]]; then
        enc_info="DISABLED"
    else
        enc_info="$(cipher_name "$EDGE_CIPHER")"
    fi

    local title="Edge Node"
    [[ -n "$instance_name" ]] && title="Edge: ${instance_name}"

    print_box "$title" \
        "Community:     ${EDGE_COMMUNITY}" \
        "Supernode:     ${EDGE_SUPERNODE}" \
        "$(if [[ -n "$EDGE_SUPERNODE2" ]]; then echo "Backup SN:     ${EDGE_SUPERNODE2}"; else echo "Backup SN:     (none)"; fi)" \
        "VPN Address:   ${EDGE_IP}/${EDGE_CIDR}" \
        "Encryption:    ${enc_info}" \
        "MTU:           ${EDGE_MTU}" \
        "Routing:       $(if [[ "$EDGE_ROUTING" == "y" ]]; then echo "enabled"; else echo "disabled"; fi)" \
        "Multicast:     $(if [[ "$EDGE_MULTICAST" == "y" ]]; then echo "enabled"; else echo "disabled"; fi)" \
        "Compression:   $(compression_name "${EDGE_COMPRESSION}")" \
        "Mgmt Port:     ${EDGE_MGMT_PORT}" \
        "Description:   ${EDGE_DESCRIPTION:-"(none)"}"

    echo ""
    printf "  ${DIM}Command:${RESET}\n"
    printf "  ${GRAY}%s${RESET}\n" "$(build_edge_display_cmd)"
}

# ── Use Case Presets ─────────────────────────────────────────────────────────

USECASE=""

select_usecase() {
    print_section "Use Case Preset"
    print_info "Choose a preset for smart defaults, or go fully custom."

    ask_choice "Select preset" USECASE \
        "Home VPN        — Private network for your personal devices" \
        "Remote Access   — Reach home/office from anywhere" \
        "Site-to-Site    — Bridge two separate LANs" \
        "Gaming / LAN    — Low-latency direct P2P, minimal overhead" \
        "IoT Mesh        — Lightweight encrypted mesh for IoT devices" \
        "Custom          — Full manual configuration" || return 1
}

apply_usecase_defaults() {
    case $USECASE in
        1) # Home VPN
            EDGE_COMMUNITY="home"
            EDGE_CIPHER="3"
            EDGE_IP="10.88.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="n"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="$(hostname -s)"
            ;;
        2) # Remote Access
            EDGE_COMMUNITY="remote"
            EDGE_CIPHER="4"
            EDGE_IP="10.90.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="y"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="$(hostname -s)"
            ;;
        3) # Site-to-Site
            EDGE_COMMUNITY="site2site"
            EDGE_CIPHER="3"
            EDGE_IP="10.100.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="y"
            EDGE_MULTICAST="y"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="site-$(hostname -s)"
            ;;
        4) # Gaming / LAN
            EDGE_COMMUNITY="lan"
            EDGE_CIPHER="1"
            EDGE_IP="10.77.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1400"
            EDGE_ROUTING="n"
            EDGE_MULTICAST="y"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="$(hostname -s)"
            EDGE_SN_SELECT="rtt"
            ;;
        5) # IoT Mesh
            EDGE_COMMUNITY="iot"
            EDGE_CIPHER="5"
            EDGE_IP="10.66.0.1"
            EDGE_CIDR="16"
            EDGE_MTU="1000"
            EDGE_ROUTING="y"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION="1"
            EDGE_DESCRIPTION="iot-$(hostname -s)"
            ;;
        6) # Custom
            EDGE_COMMUNITY=""
            EDGE_KEY=""
            EDGE_CIPHER="3"
            EDGE_IP=""
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="n"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION=""
            ;;
    esac
}

# ── Edge Configuration Flow ─────────────────────────────────────────────────

configure_edge() {
    local _current_instance="${1:-}"
    print_section "Configure Edge"

    # Community
    while true; do
        ask "Community name" "$EDGE_COMMUNITY" EDGE_COMMUNITY
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_community "$EDGE_COMMUNITY" 2>&1); then
            break
        else
            printf "  ${RED}  ↳ %s${RESET}\n" "$err"
        fi
    done

    # Supernode
    echo ""
    print_info "Enter the supernode address your edge will connect to."
    while true; do
        ask "Supernode (host:port)" "$EDGE_SUPERNODE" EDGE_SUPERNODE
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_supernode_addr "$EDGE_SUPERNODE" 2>&1); then
            break
        else
            printf "  ${RED}  ↳ %s${RESET}\n" "$err"
        fi
    done

    if [[ -n "$EDGE_SUPERNODE2" ]]; then
        local sn2_action
        ask_choice "Backup supernode (current: ${EDGE_SUPERNODE2})" sn2_action \
            "Keep current" \
            "Change" \
            "Remove" || return 1
        case $sn2_action in
            2)
                while true; do
                    ask "Backup supernode (host:port)" "$EDGE_SUPERNODE2" EDGE_SUPERNODE2
                    $_STDIN_EOF && return 1
                    if [[ -z "$EDGE_SUPERNODE2" ]]; then break; fi
                    local err
                    if err=$(validate_supernode_addr "$EDGE_SUPERNODE2" 2>&1); then break
                    else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
                done
                ;;
            3)
                EDGE_SUPERNODE2=""
                print_status "$SYM_OK" "Backup supernode removed."
                ;;
        esac
    else
        if ask_yesno "Add a backup supernode?" "n"; then
            while true; do
                ask "Backup supernode (host:port)" "" EDGE_SUPERNODE2
                $_STDIN_EOF && return 1
                if [[ -z "$EDGE_SUPERNODE2" ]]; then break; fi
                local err
                if err=$(validate_supernode_addr "$EDGE_SUPERNODE2" 2>&1); then break
                else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
            done
        fi
    fi

    # VPN IP
    echo ""
    print_info "VPN IP address for this edge node on the virtual network."
    while true; do
        ask "VPN IP address" "$EDGE_IP" EDGE_IP
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_private_ip "$EDGE_IP" 2>&1); then
            if ip_conflicts_with_interface "$EDGE_IP"; then
                printf "  ${YELLOW}  ↳ Warning: %s is already assigned to a local interface${RESET}\n" "$EDGE_IP"
                if ask_yesno "Use it anyway?" "n"; then break; fi
            else
                break
            fi
        else
            printf "  ${RED}  ↳ %s${RESET}\n" "$err"
        fi
    done

    while true; do
        ask "Subnet CIDR" "$EDGE_CIDR" EDGE_CIDR
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_cidr "$EDGE_CIDR" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    # Check VPN IP conflicts with other instances
    local conflict_inst
    conflict_inst=$(check_ip_conflict_with_instances "$EDGE_IP" "$_current_instance")
    if [[ -n "$conflict_inst" ]]; then
        printf "  ${YELLOW}  ↳ Warning: IP %s is already used by instance '%s'${RESET}\n" "$EDGE_IP" "$conflict_inst"
    fi

    # Encryption
    echo ""
    if [[ "$EDGE_CIPHER" == "1" ]]; then
        print_info "Encryption is disabled for this preset."
        if ask_yesno "Enable encryption?" "n"; then
            ask_choice "Cipher" EDGE_CIPHER \
                "Twofish" \
                "AES-256-CBC (recommended)" \
                "ChaCha20 (fast, modern)" \
                "Speck-CTR (lightweight)" || return 1
            EDGE_CIPHER=$((EDGE_CIPHER + 1))
        fi
    else
        ask_choice "Cipher" EDGE_CIPHER \
            "None (no encryption)" \
            "Twofish" \
            "AES-256-CBC (recommended)" \
            "ChaCha20 (fast, modern)" \
            "Speck-CTR (lightweight)" || return 1
    fi

    # Encryption key
    if [[ "$EDGE_CIPHER" != "1" ]]; then
        echo ""
        print_info "Note: key is passed as a command-line argument and visible in process listings."
        if [[ -n "$EDGE_KEY" ]]; then
            print_info "Current key is set. Press Enter to keep, or type a new one."
        fi
        while true; do
            if [[ -n "$EDGE_KEY" ]]; then
                local new_key
                printf "  ${SYM_LOCK} ${BOLD}Encryption key${RESET} ${DIM}[keep current]${RESET}: "
                if ! read -rs new_key; then _STDIN_EOF=true; echo ""; return 1; fi
                echo ""
                if [[ -z "$new_key" ]]; then
                    break
                fi
                EDGE_KEY="$new_key"
            else
                ask_password "Encryption key (min 8 chars)" EDGE_KEY
                $_STDIN_EOF && return 1
            fi
            if [[ -z "$EDGE_KEY" ]]; then
                printf "  ${RED}  ↳ Key cannot be empty when encryption is enabled${RESET}\n"
                $_STDIN_EOF && return 1
                continue
            fi
            local strength
            strength=$(check_key_strength "$EDGE_KEY")
            case $strength in
                weak)
                    printf "  ${RED}  ↳ Key too short (min 8 characters)${RESET}\n"
                    EDGE_KEY=""
                    $_STDIN_EOF && return 1
                    continue
                    ;;
                fair)
                    printf "  ${YELLOW}  ↳ Key strength: FAIR — consider using 12+ chars with mixed case/digits${RESET}\n"
                    if ask_yesno "Use this key?" "y"; then break; fi
                    EDGE_KEY=""
                    ;;
                good)
                    printf "  ${GREEN}  ↳ Key strength: GOOD${RESET}\n"
                    break
                    ;;
                strong)
                    printf "  ${GREEN}  ↳ Key strength: STRONG${RESET}\n"
                    break
                    ;;
            esac
        done
    else
        EDGE_KEY=""
    fi

    # Advanced options
    echo ""
    if ask_yesno "Configure advanced options? (MTU, routing, compression, etc.)" "n"; then
        configure_edge_advanced || return 1
    fi
}

configure_edge_advanced() {
    echo ""
    print_info "── Advanced Edge Options ──"
    echo ""

    # MTU
    while true; do
        ask "MTU (500-1500)" "$EDGE_MTU" EDGE_MTU
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_mtu "$EDGE_MTU" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    # Packet forwarding
    if ask_yesno "Enable packet forwarding?" "${EDGE_ROUTING}"; then
        EDGE_ROUTING="y"

        echo ""
        print_info "Add routes to push through the VPN (e.g. 0.0.0.0/0 for default route)."
        print_info "Leave empty to skip."
        local route_input
        ask "Route (CIDR/bitlen:gateway or empty)" "${EDGE_ROUTES:-}" route_input
        EDGE_ROUTES="$route_input"
    else
        EDGE_ROUTING="n"
        EDGE_ROUTES=""
    fi

    # Multicast
    if ask_yesno "Accept multicast MAC addresses?" "${EDGE_MULTICAST}"; then
        EDGE_MULTICAST="y"
    else
        EDGE_MULTICAST="n"
    fi

    # Compression
    echo ""
    ask_choice "Compression" EDGE_COMPRESSION \
        "None (default)" \
        "LZO1X (fast)" \
        "ZSTD (better ratio, if available)" || return 1
    case $EDGE_COMPRESSION in
        1) EDGE_COMPRESSION="" ;;
        2) EDGE_COMPRESSION="1" ;;
        3) EDGE_COMPRESSION="2" ;;
    esac

    # Supernode selection
    echo ""
    ask_choice "Supernode selection strategy" EDGE_SN_SELECT \
        "By load (default)" \
        "By round-trip time (RTT)" \
        "By MAC address" || return 1
    case $EDGE_SN_SELECT in
        1) EDGE_SN_SELECT="" ;;
        2) EDGE_SN_SELECT="rtt" ;;
        3) EDGE_SN_SELECT="mac" ;;
    esac

    # MAC address
    echo ""
    print_info "Leave empty for random MAC (recommended)."
    local mac_input
    ask "Fixed MAC address" "${EDGE_MAC:-}" mac_input
    $_STDIN_EOF && return 1
    if [[ -n "$mac_input" ]]; then
        while true; do
            local err
            if err=$(validate_mac "$mac_input" 2>&1); then
                EDGE_MAC="$mac_input"
                break
            else
                printf "  ${RED}  ↳ %s${RESET}\n" "$err"
                ask "Fixed MAC address" "" mac_input
                $_STDIN_EOF && return 1
                if [[ -z "$mac_input" ]]; then
                    EDGE_MAC=""
                    break
                fi
            fi
        done
    else
        EDGE_MAC=""
    fi

    # Local port
    echo ""
    print_info "Local UDP port for edge (0 = auto-assign by OS)."
    while true; do
        ask "Local port" "$EDGE_LOCAL_PORT" EDGE_LOCAL_PORT
        $_STDIN_EOF && return 1
        if [[ "$EDGE_LOCAL_PORT" == "0" ]]; then break; fi
        local err
        if err=$(validate_port "$EDGE_LOCAL_PORT" "Local port" 2>&1); then
            if ! check_port_available "$EDGE_LOCAL_PORT"; then
                printf "  ${YELLOW}  ↳ Warning: port %s appears to be in use${RESET}\n" "$EDGE_LOCAL_PORT"
                if ask_yesno "Use it anyway?" "n"; then break; fi
            else
                break
            fi
        else
            printf "  ${RED}  ↳ %s${RESET}\n" "$err"
        fi
    done

    # Management port
    while true; do
        ask "Management port" "$EDGE_MGMT_PORT" EDGE_MGMT_PORT
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_port "$EDGE_MGMT_PORT" "Management port" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    # Description
    ask "Device description / username" "$EDGE_DESCRIPTION" EDGE_DESCRIPTION

    # Verbosity
    echo ""
    ask_choice "Verbosity level" EDGE_VERBOSITY \
        "Normal" \
        "Verbose (-v)" \
        "Very verbose (-v -v)" \
        "Debug (-v -v -v)" || return 1
    EDGE_VERBOSITY=$(( EDGE_VERBOSITY - 1 ))
}

# ── Conflict Detection ───────────────────────────────────────────────────────

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

# ── CRUD: Create ─────────────────────────────────────────────────────────────

do_create() {
    local instance_name="${1:-}"

    detect_binaries
    require_edge_binary || return 1

    print_header "Create Edge Instance"

    # Instance name
    if [[ -z "$instance_name" ]]; then
        while true; do
            ask "Instance name (e.g. home, office, iot)" "" instance_name
            $_STDIN_EOF && return 1
            local err
            if err=$(validate_instance_name "$instance_name" 2>&1); then
                if instance_exists "$instance_name"; then
                    printf "  ${RED}  ↳ Instance '%s' already exists. Use 'edit' to modify.${RESET}\n" "$instance_name"
                    instance_name=""
                    continue
                fi
                break
            else
                printf "  ${RED}  ↳ %s${RESET}\n" "$err"
                instance_name=""
            fi
        done
    else
        local err
        if ! err=$(validate_instance_name "$instance_name" 2>&1); then
            print_status "$SYM_FAIL" "$err"
            return 1
        fi
        if instance_exists "$instance_name"; then
            print_status "$SYM_FAIL" "Instance '$instance_name' already exists. Use 'edit' to modify."
            return 1
        fi
    fi

    print_status "$SYM_OK" "Creating instance: ${BOLD}${instance_name}${RESET}"

    # Reset and configure
    reset_edge_defaults
    EDGE_DESCRIPTION="$(hostname -s)-${instance_name}"

    select_usecase || return 1
    apply_usecase_defaults
    EDGE_MGMT_PORT=$(next_available_mgmt_port)

    configure_edge "$instance_name" || return 1

    # Port conflict check
    local port_conflict
    port_conflict=$(check_mgmt_port_conflict "$EDGE_MGMT_PORT" "$instance_name")
    if [[ -n "$port_conflict" ]]; then
        printf "  ${YELLOW}  ↳ Mgmt port %s conflicts with instance '%s'. Auto-assigning.${RESET}\n" "$EDGE_MGMT_PORT" "$port_conflict"
        EDGE_MGMT_PORT=$(next_available_mgmt_port)
        printf "  ${GREEN}  ↳ Using port %s${RESET}\n" "$EDGE_MGMT_PORT"
    fi

    # Review
    review_edge_config "$instance_name"

    echo ""
    if ! ask_yesno "Save this configuration?" "y"; then
        print_status "$SYM_WARN" "Aborted."
        return
    fi

    # Save config
    local conf_dir
    conf_dir="$(instance_config_dir "$instance_name")"
    mkdir -p "$conf_dir"
    chmod 700 "$conf_dir"
    generate_edge_conf "$(instance_config_path "$instance_name")" "$instance_name"
    chmod 600 "$(instance_config_path "$instance_name")"
    print_status "$SYM_OK" "Config saved: $(instance_config_path "$instance_name")"

    # Ask about daemon installation
    echo ""
    if ask_yesno "Install as LaunchDaemon (auto-start at boot)?" "y"; then
        install_instance_daemon "$instance_name"
    fi

    # Ask about starting now
    if instance_plist_installed "$instance_name"; then
        echo ""
        if ask_yesno "Start this instance now?" "y"; then
            do_start "$instance_name"
        fi
    fi

    echo ""
    print_status "$SYM_OK" "${BOLD}Instance '${instance_name}' created successfully.${RESET}"
}

# ── CRUD: List ───────────────────────────────────────────────────────────────

do_list() {
    detect_binaries

    if ! sudo -n true 2>/dev/null; then
        print_info "Tip: run with sudo cached for accurate daemon status"
    fi

    print_header "Edge Instances"

    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} == 0 )); then
        print_info "No instances configured."
        print_info "Create one with: $(basename "$0") create <name>"
        echo ""
        return
    fi

    # Table header
    printf "  ${WHITE}%-18s %-20s %-14s %-16s %s${RESET}\n" \
        "NAME" "STATUS" "COMMUNITY" "VPN IP" "SUPERNODE"
    printf "  ${GRAY}"
    printf '─%.0s' $(seq 1 80)
    printf "${RESET}\n"

    local name
    for name in "${names[@]}"; do
        if ! parse_edge_conf "$(instance_config_path "$name")"; then continue; fi

        local status_str pid_str=""
        if instance_is_running "$name"; then
            local pid
            pid=$(instance_pid "$name")
            status_str="${GREEN}running${RESET}"
            [[ -n "$pid" ]] && pid_str=" (${pid})"
        elif instance_is_loaded "$name"; then
            status_str="${YELLOW}loaded${RESET}"
        elif instance_plist_installed "$name"; then
            status_str="${YELLOW}installed${RESET}"
        else
            status_str="${GRAY}config only${RESET}"
        fi

        printf "  %-18s %-20b %-14s %-16s %s\n" \
            "$name" \
            "${status_str}${pid_str}" \
            "$EDGE_COMMUNITY" \
            "${EDGE_IP}" \
            "$EDGE_SUPERNODE"
    done

    printf "  ${GRAY}"
    printf '─%.0s' $(seq 1 80)
    printf "${RESET}\n"
    printf "  ${DIM}%d instance(s)${RESET}\n" "${#names[@]}"
    echo ""
}

# ── CRUD: Show ───────────────────────────────────────────────────────────────

do_show() {
    local instance_name="${1:-}"
    detect_binaries

    if ! sudo -n true 2>/dev/null; then
        print_info "Tip: run with sudo cached for accurate daemon status"
    fi

    if [[ -z "$instance_name" ]]; then
        instance_name=$(pick_instance "Show details for") || true
        [[ -z "$instance_name" ]] && return
    fi

    if ! instance_exists "$instance_name"; then
        print_status "$SYM_FAIL" "Instance '$instance_name' not found."
        return 1
    fi

    if ! parse_edge_conf "$(instance_config_path "$instance_name")"; then
        print_status "$SYM_FAIL" "Could not read config for '$instance_name'."
        return 1
    fi

    print_header "Instance: ${instance_name}"

    # Status
    printf "  ${WHITE}Status${RESET}\n"
    if instance_is_running "$instance_name"; then
        local pid
        pid=$(instance_pid "$instance_name")
        print_status "$SYM_OK" "Running (PID ${pid:-?})"
        local proc_info
        proc_info=$(ps -p "${pid:-0}" -o etime=,rss= 2>/dev/null || echo "")
        if [[ -n "$proc_info" ]]; then
            local etime rss_kb
            etime=$(echo "$proc_info" | awk '{print $1}')
            rss_kb=$(echo "$proc_info" | awk '{print $2}')
            if [[ "$rss_kb" =~ ^[0-9]+$ ]] && (( rss_kb > 0 )); then
                print_info "  Uptime: ${etime}    Memory: $((rss_kb / 1024))MB"
            elif [[ -n "$etime" ]]; then
                print_info "  Uptime: ${etime}"
            fi
        fi
    elif instance_is_loaded "$instance_name"; then
        print_status "$SYM_WARN" "Loaded but not running (may be crashing)"
    elif instance_plist_installed "$instance_name"; then
        print_status "$SYM_DOT" "Daemon installed, not loaded"
    else
        print_status "$SYM_DOT" "Config only (no daemon installed)"
    fi

    # Config
    review_edge_config "$instance_name"

    # Files
    echo ""
    printf "  ${WHITE}Files${RESET}\n"
    print_info "  Config: $(instance_config_path "$instance_name")"
    if instance_plist_installed "$instance_name"; then
        print_info "  Plist:  $(instance_plist_path "$instance_name")"
    fi
    print_info "  Log:    $(instance_log_path "$instance_name")"

    # Recent log lines
    local log_path
    log_path="$(instance_log_path "$instance_name")"
    if [[ -f "$log_path" ]]; then
        echo ""
        printf "  ${WHITE}Recent Log${RESET}\n"
        tail -5 "$log_path" 2>/dev/null | while IFS= read -r line; do
            printf "  ${GRAY}  %s${RESET}\n" "$line"
        done
    fi

    echo ""
}

# ── CRUD: Edit ───────────────────────────────────────────────────────────────

do_edit() {
    local instance_name="${1:-}"
    detect_binaries
    require_edge_binary || return 1
    ensure_sudo

    if [[ -z "$instance_name" ]]; then
        instance_name=$(pick_instance "Edit") || true
        [[ -z "$instance_name" ]] && return
    fi

    if ! instance_exists "$instance_name"; then
        print_status "$SYM_FAIL" "Instance '$instance_name' not found."
        return 1
    fi

    if ! parse_edge_conf "$(instance_config_path "$instance_name")"; then
        print_status "$SYM_FAIL" "Could not read config for '$instance_name'."
        return 1
    fi

    print_header "Edit Instance: ${instance_name}"

    # Show current config
    review_edge_config "$instance_name"

    echo ""
    local edit_choice
    ask_choice "What to edit?" edit_choice \
        "Network settings (community, supernode, VPN IP)" \
        "Security settings (cipher, key)" \
        "Advanced settings (MTU, routing, compression, ports, etc.)" \
        "All settings" \
        "Cancel" || return 1

    local _edit_rc=0
    case $edit_choice in
        1) edit_network_settings "$instance_name" || _edit_rc=$? ;;
        2) edit_security_settings || _edit_rc=$? ;;
        3) configure_edge_advanced || _edit_rc=$? ;;
        4) configure_edge "$instance_name" || _edit_rc=$? ;;
        5)
            print_status "$SYM_DOT" "No changes made."
            return
            ;;
    esac
    if (( _edit_rc != 0 )); then
        print_status "$SYM_WARN" "Configuration aborted."
        return 1
    fi

    # Port conflict check
    local port_conflict
    port_conflict=$(check_mgmt_port_conflict "$EDGE_MGMT_PORT" "$instance_name")
    if [[ -n "$port_conflict" ]]; then
        printf "  ${YELLOW}  ↳ Mgmt port %s conflicts with instance '%s'. Auto-assigning.${RESET}\n" "$EDGE_MGMT_PORT" "$port_conflict"
        EDGE_MGMT_PORT=$(next_available_mgmt_port)
        printf "  ${GREEN}  ↳ Using port %s${RESET}\n" "$EDGE_MGMT_PORT"
    fi

    # Review changes
    echo ""
    review_edge_config "$instance_name"

    echo ""
    if ! ask_yesno "Save changes?" "y"; then
        print_status "$SYM_WARN" "Changes discarded."
        return
    fi

    # Save (with backup for rollback)
    local conf_path
    conf_path="$(instance_config_path "$instance_name")"
    local backup_path="${conf_path}.bak"

    cp "$conf_path" "$backup_path"
    generate_edge_conf "$conf_path" "$instance_name"
    chmod 600 "$conf_path"
    print_status "$SYM_OK" "Config updated."

    # Update daemon if installed
    if instance_plist_installed "$instance_name"; then
        local was_running=false
        if instance_is_running "$instance_name"; then
            was_running=true
            do_stop "$instance_name"
        fi
        if ! install_instance_daemon "$instance_name"; then
            print_status "$SYM_FAIL" "Daemon update failed — rolling back config."
            mv "$backup_path" "$conf_path"
            if $was_running; then
                install_instance_daemon "$instance_name" 2>/dev/null || true
                do_start "$instance_name" 2>/dev/null || true
            fi
            return 1
        fi
        if $was_running; then
            do_start "$instance_name"
            print_status "$SYM_OK" "Instance restarted with new configuration."
        else
            echo ""
            if ask_yesno "Start this instance now?" "y"; then
                do_start "$instance_name"
            fi
        fi
    fi

    rm -f "$backup_path"
    echo ""
    print_status "$SYM_OK" "${BOLD}Instance '${instance_name}' updated.${RESET}"
}

edit_network_settings() {
    local _current_instance="${1:-}"
    print_section "Edit Network Settings"

    # Community
    while true; do
        ask "Community name" "$EDGE_COMMUNITY" EDGE_COMMUNITY
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_community "$EDGE_COMMUNITY" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    # Supernode
    echo ""
    while true; do
        ask "Supernode (host:port)" "$EDGE_SUPERNODE" EDGE_SUPERNODE
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_supernode_addr "$EDGE_SUPERNODE" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    # Backup supernode with option to remove
    echo ""
    if [[ -n "$EDGE_SUPERNODE2" ]]; then
        local sn2_action
        ask_choice "Backup supernode (current: ${EDGE_SUPERNODE2})" sn2_action \
            "Keep current" \
            "Change" \
            "Remove" || return 1
        case $sn2_action in
            2)
                while true; do
                    ask "Backup supernode (host:port)" "$EDGE_SUPERNODE2" EDGE_SUPERNODE2
                    $_STDIN_EOF && return 1
                    if [[ -z "$EDGE_SUPERNODE2" ]]; then break; fi
                    local err
                    if err=$(validate_supernode_addr "$EDGE_SUPERNODE2" 2>&1); then break
                    else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
                done
                ;;
            3)
                EDGE_SUPERNODE2=""
                print_status "$SYM_OK" "Backup supernode removed."
                ;;
        esac
    else
        if ask_yesno "Add a backup supernode?" "n"; then
            while true; do
                ask "Backup supernode (host:port)" "" EDGE_SUPERNODE2
                $_STDIN_EOF && return 1
                if [[ -z "$EDGE_SUPERNODE2" ]]; then break; fi
                local err
                if err=$(validate_supernode_addr "$EDGE_SUPERNODE2" 2>&1); then break
                else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
            done
        fi
    fi

    # VPN IP
    echo ""
    while true; do
        ask "VPN IP address" "$EDGE_IP" EDGE_IP
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_private_ip "$EDGE_IP" 2>&1); then
            if ip_conflicts_with_interface "$EDGE_IP"; then
                printf "  ${YELLOW}  ↳ Warning: %s is already on a local interface${RESET}\n" "$EDGE_IP"
                if ask_yesno "Use it anyway?" "n"; then break; fi
            else
                break
            fi
        else
            printf "  ${RED}  ↳ %s${RESET}\n" "$err"
        fi
    done

    while true; do
        ask "Subnet CIDR" "$EDGE_CIDR" EDGE_CIDR
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_cidr "$EDGE_CIDR" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    # Cross-instance IP conflict check
    local conflict_inst
    conflict_inst=$(check_ip_conflict_with_instances "$EDGE_IP" "$_current_instance")
    if [[ -n "$conflict_inst" ]]; then
        printf "  ${YELLOW}  ↳ Warning: IP %s is already used by instance '%s'${RESET}\n" "$EDGE_IP" "$conflict_inst"
    fi
}

edit_security_settings() {
    print_section "Edit Security Settings"

    echo ""
    ask_choice "Cipher" EDGE_CIPHER \
        "None (no encryption)" \
        "Twofish" \
        "AES-256-CBC (recommended)" \
        "ChaCha20 (fast, modern)" \
        "Speck-CTR (lightweight)" || return 1

    if [[ "$EDGE_CIPHER" != "1" ]]; then
        echo ""
        if [[ -n "$EDGE_KEY" ]]; then
            print_info "Current key is set. Press Enter to keep, or type a new one."
        fi
        while true; do
            if [[ -n "$EDGE_KEY" ]]; then
                local new_key
                printf "  ${SYM_LOCK} ${BOLD}Encryption key${RESET} ${DIM}[keep current]${RESET}: "
                if ! read -rs new_key; then _STDIN_EOF=true; echo ""; return 1; fi
                echo ""
                if [[ -z "$new_key" ]]; then break; fi
                EDGE_KEY="$new_key"
            else
                ask_password "Encryption key (min 8 chars)" EDGE_KEY
                $_STDIN_EOF && return 1
            fi
            if [[ -z "$EDGE_KEY" ]]; then
                printf "  ${RED}  ↳ Key cannot be empty when encryption is enabled${RESET}\n"
                $_STDIN_EOF && return 1
                continue
            fi
            local strength
            strength=$(check_key_strength "$EDGE_KEY")
            case $strength in
                weak)
                    printf "  ${RED}  ↳ Key too short (min 8 characters)${RESET}\n"
                    EDGE_KEY=""
                    $_STDIN_EOF && return 1
                    continue
                    ;;
                fair)
                    printf "  ${YELLOW}  ↳ Key strength: FAIR${RESET}\n"
                    if ask_yesno "Use this key?" "y"; then break; fi
                    EDGE_KEY=""
                    ;;
                good|strong)
                    printf "  ${GREEN}  ↳ Key strength: %s${RESET}\n" "$(echo "$strength" | tr '[:lower:]' '[:upper:]')"
                    break
                    ;;
            esac
        done
    else
        EDGE_KEY=""
    fi
}

# ── CRUD: Delete ─────────────────────────────────────────────────────────────

do_delete() {
    local instance_name="${1:-}"
    detect_binaries

    if [[ -z "$instance_name" ]]; then
        instance_name=$(pick_instance "Delete") || true
        [[ -z "$instance_name" ]] && return
    fi

    if ! instance_exists "$instance_name"; then
        print_status "$SYM_FAIL" "Instance '$instance_name' not found."
        return 1
    fi

    if ! parse_edge_conf "$(instance_config_path "$instance_name")"; then
        print_status "$SYM_WARN" "Could not read config for '$instance_name' (may be corrupted)."
    fi

    print_header "Delete Instance: ${instance_name}"

    review_edge_config "$instance_name"

    echo ""
    printf "  ${RED}${BOLD}This will permanently remove this instance.${RESET}\n"
    if ! ask_yesno "Are you sure?" "n"; then
        print_status "$SYM_DOT" "Aborted."
        return
    fi

    # Stop if running
    if instance_is_running "$instance_name" || instance_is_loaded "$instance_name"; then
        print_status "$SYM_ARROW" "Stopping instance..."
        do_stop "$instance_name" 2>/dev/null || true
    fi

    # Remove plist
    if instance_plist_installed "$instance_name"; then
        local plist_path
        plist_path="$(instance_plist_path "$instance_name")"
        sudo launchctl unload "$plist_path" 2>/dev/null || true
        sudo rm -f "$plist_path"
        print_status "$SYM_OK" "Removed LaunchDaemon"
    fi

    # Remove config
    local conf_dir
    conf_dir="$(instance_config_dir "$instance_name")"
    rm -rf "$conf_dir"
    print_status "$SYM_OK" "Removed config directory"

    # Ask about logs
    local log_path
    log_path="$(instance_log_path "$instance_name")"
    if [[ -f "$log_path" ]]; then
        if ask_yesno "Remove log file ($log_path)?" "y"; then
            sudo rm -f "$log_path"
            print_status "$SYM_OK" "Removed log file"
        fi
    fi

    echo ""
    print_status "$SYM_OK" "${BOLD}Instance '${instance_name}' deleted.${RESET}"
}

# ── Log Rotation ─────────────────────────────────────────────────────────────

install_logrotation() {
    local plist_path="${PLIST_DIR}/${LOGROTATE_LABEL}.plist"

    [[ -f "$plist_path" ]] && return 0

    local rotate_script="${SCRIPT_DIR}/n2n-logrotate.sh"
    if [[ ! -f "$rotate_script" ]]; then
        print_status "$SYM_WARN" "Log rotation script not found at $rotate_script"
        return 1
    fi

    local tmp_plist
    tmp_plist=$(mktemp /tmp/n2n-logrotate-plist.XXXXXX)
    _CLEANUP_FILES+=("$tmp_plist")

    cat > "$tmp_plist" <<LREOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LOGROTATE_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>${rotate_script}</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>4</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
</dict>
</plist>
LREOF

    sudo cp "$tmp_plist" "$plist_path"
    sudo chown root:wheel "$plist_path"
    sudo chmod 644 "$plist_path"
    sudo launchctl load "$plist_path" 2>/dev/null || true
    rm -f "$tmp_plist"

    print_status "$SYM_OK" "Log rotation installed (daily at 04:30, 5 MB threshold)"
}

remove_logrotation() {
    local plist_path="${PLIST_DIR}/${LOGROTATE_LABEL}.plist"
    if [[ -f "$plist_path" ]]; then
        sudo launchctl unload "$plist_path" 2>/dev/null || true
        sudo rm -f "$plist_path"
    fi
}

# ── Service Control ──────────────────────────────────────────────────────────

install_instance_daemon() {
    local instance_name="$1"

    if ! parse_edge_conf "$(instance_config_path "$instance_name")"; then
        print_status "$SYM_FAIL" "Could not read config for '$instance_name'. Aborting daemon install."
        return 1
    fi

    local plist_path
    plist_path="$(instance_plist_path "$instance_name")"

    # Always attempt unload — idempotent, guards against stale state
    sudo launchctl unload "$plist_path" 2>/dev/null || true

    local tmp_plist
    tmp_plist=$(mktemp /tmp/n2n-edge-plist.XXXXXX)
    _CLEANUP_FILES+=("$tmp_plist")
    chmod 600 "$tmp_plist"
    generate_edge_plist "$tmp_plist" "$instance_name"

    sudo cp "$tmp_plist" "$plist_path"
    sudo chown root:wheel "$plist_path"
    if [[ -n "$EDGE_KEY" ]]; then
        sudo chmod 600 "$plist_path"
    else
        sudo chmod 644 "$plist_path"
    fi
    rm -f "$tmp_plist"

    print_status "$SYM_OK" "LaunchDaemon installed: $(instance_plist_label "$instance_name")"

    install_logrotation
}

do_start() {
    local instance_name="${1:-}"
    detect_binaries
    ensure_sudo

    if [[ "$instance_name" == "--all" ]] || [[ "$instance_name" == "all" ]]; then
        do_start_all
        return
    fi

    if [[ -z "$instance_name" ]]; then
        instance_name=$(pick_instance "Start") || true
        [[ -z "$instance_name" ]] && return
    fi

    if ! instance_exists "$instance_name"; then
        print_status "$SYM_FAIL" "Instance '$instance_name' not found."
        return 1
    fi

    if instance_is_running "$instance_name"; then
        print_status "$SYM_WARN" "Instance '$instance_name' is already running."
        return
    fi

    if ! instance_plist_installed "$instance_name"; then
        print_status "$SYM_ARROW" "No daemon installed. Installing first..."
        require_edge_binary || return 1
        if ! install_instance_daemon "$instance_name"; then
            return 1
        fi
    fi

    local plist_path
    plist_path="$(instance_plist_path "$instance_name")"

    if ! instance_is_loaded "$instance_name"; then
        sudo launchctl load "$plist_path"
    fi
    sudo launchctl start "$(instance_plist_label "$instance_name")"

    sleep 1
    if instance_is_running "$instance_name"; then
        local pid
        pid=$(instance_pid "$instance_name")
        print_status "$SYM_OK" "Started '${instance_name}' (PID ${pid:-?})"
    else
        print_status "$SYM_WARN" "Start command sent for '${instance_name}', but process not detected yet."
        print_info "Check log: tail -f $(instance_log_path "$instance_name")"
    fi
}

do_start_all() {
    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} == 0 )); then
        print_status "$SYM_DOT" "No instances configured."
        return
    fi

    local name
    for name in "${names[@]}"; do
        if ! instance_is_running "$name"; then
            do_start "$name"
        else
            print_status "$SYM_DOT" "'${name}' already running."
        fi
    done
}

do_stop() {
    local instance_name="${1:-}"
    detect_binaries
    ensure_sudo

    if [[ "$instance_name" == "--all" ]] || [[ "$instance_name" == "all" ]]; then
        do_stop_all
        return
    fi

    if [[ -z "$instance_name" ]]; then
        instance_name=$(pick_instance "Stop") || true
        [[ -z "$instance_name" ]] && return
    fi

    if ! instance_exists "$instance_name"; then
        print_status "$SYM_FAIL" "Instance '$instance_name' not found."
        return 1
    fi

    local label
    label="$(instance_plist_label "$instance_name")"
    local plist_path
    plist_path="$(instance_plist_path "$instance_name")"

    local stopped=false

    if instance_is_loaded "$instance_name"; then
        sudo launchctl stop "$label" 2>/dev/null || true
        sudo launchctl unload "$plist_path" 2>/dev/null || true
        stopped=true
    else
        # Belt-and-suspenders: try unload even if detection missed it (stale sudo, etc.)
        sudo launchctl unload "$plist_path" 2>/dev/null || true
    fi

    # Kill any lingering process that launchctl didn't clean up
    local pid
    pid=$(instance_pid "$instance_name")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        sudo kill "$pid" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$pid" 2>/dev/null; then
            sudo kill -9 "$pid" 2>/dev/null || true
        fi
        stopped=true
    fi

    if $stopped; then
        print_status "$SYM_OK" "Stopped '${instance_name}'"
        print_info "  Will auto-start again at next boot. Use 'delete' to remove permanently."
    else
        print_status "$SYM_DOT" "'${instance_name}' is not running."
    fi
}

do_stop_all() {
    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} == 0 )); then
        print_status "$SYM_DOT" "No instances configured."
        return
    fi

    local name
    for name in "${names[@]}"; do
        if instance_is_running "$name" || instance_is_loaded "$name"; then
            do_stop "$name"
        else
            print_status "$SYM_DOT" "'${name}' already stopped."
        fi
    done
}

do_restart() {
    local instance_name="${1:-}"

    if [[ "$instance_name" == "--all" ]] || [[ "$instance_name" == "all" ]]; then
        do_restart_all
        return
    fi

    if [[ -z "$instance_name" ]]; then
        instance_name=$(pick_instance "Restart") || true
        [[ -z "$instance_name" ]] && return
    fi

    do_stop "$instance_name"
    sleep 1
    do_start "$instance_name"
}

do_restart_all() {
    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} == 0 )); then
        print_status "$SYM_DOT" "No instances configured."
        return
    fi

    local name
    for name in "${names[@]}"; do
        do_restart "$name"
    done
}

do_logs() {
    local instance_name="${1:-}"
    detect_binaries

    if [[ -z "$instance_name" ]]; then
        instance_name=$(pick_instance "View logs for") || true
        [[ -z "$instance_name" ]] && return
    fi

    if ! instance_exists "$instance_name"; then
        print_status "$SYM_FAIL" "Instance '$instance_name' not found."
        return 1
    fi

    local log_path
    log_path="$(instance_log_path "$instance_name")"

    if [[ ! -f "$log_path" ]]; then
        print_status "$SYM_DOT" "No log file yet: $log_path"
        return
    fi

    echo ""
    printf "  ${DIM}Log: %s (Ctrl-C to stop)${RESET}\n" "$log_path"
    echo ""
    tail -f "$log_path"
}

# ── Instance Picker ──────────────────────────────────────────────────────────

pick_instance() {
    local action_label="${1:-Select}"

    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} == 0 )); then
        print_status "$SYM_DOT" "No instances configured." >&2
        return 1
    fi

    if (( ${#names[@]} == 1 )); then
        printf "  ${DIM}Auto-selected instance: %s${RESET}\n" "${names[0]}" >&2
        echo "${names[0]}"
        return
    fi

    echo "" >&2
    local i=1
    local name
    for name in "${names[@]}"; do
        local status
        status="$(instance_status_plain "$name")"
        printf "    ${WHITE}%d)${RESET} %s ${DIM}(%s)${RESET}\n" "$i" "$name" "$status" >&2
        i=$((i + 1))
    done
    echo "" >&2

    local choice
    while true; do
        printf "  ${SYM_ARROW} ${BOLD}%s which instance?${RESET} ${DIM}[1-%d]${RESET}: " "$action_label" "${#names[@]}" >&2
        if ! read -r choice; then
            echo "" >&2
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            echo "${names[$((choice - 1))]}"
            return
        fi
        printf "  ${RED}Invalid choice.${RESET}\n" >&2
    done
}

# ── Supernode Management ─────────────────────────────────────────────────────

SN_PORT="7777"
SN_MGMT_PORT="5645"
SN_FEDERATION=""
SN_COMMUNITY_FILE=""
SN_AUTO_IP=""
SN_VERBOSITY="0"
SN_SPOOFING_PROT="y"

parse_supernode_conf() {
    local conf_path="$1"
    SN_PORT="7777"
    SN_MGMT_PORT="5645"
    SN_FEDERATION=""
    SN_COMMUNITY_FILE=""
    SN_AUTO_IP=""
    SN_VERBOSITY="0"
    SN_SPOOFING_PROT="y"

    [[ -f "$conf_path" ]] || return 1

    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        case "$line" in
            -p=*) SN_PORT="${line#-p=}" ;;
            -t=*) SN_MGMT_PORT="${line#-t=}" ;;
            -F=*) SN_FEDERATION="${line#-F=}" ;;
            -c=*) SN_COMMUNITY_FILE="${line#-c=}" ;;
            -a=*) SN_AUTO_IP="${line#-a=}" ;;
            -M)   SN_SPOOFING_PROT="n" ;;
            -v)   SN_VERBOSITY=$((SN_VERBOSITY + 1)) ;;
            -f)   ;;
        esac
    done < "$conf_path"
}

generate_supernode_conf() {
    local conf_path="$1"
    local lines=()
    lines+=("# N2N Supernode Configuration")
    lines+=("# Generated on $(date '+%Y-%m-%d %H:%M:%S')")
    lines+=("")
    lines+=("-p=${SN_PORT}")
    [[ -n "$SN_FEDERATION" ]] && lines+=("-F=${SN_FEDERATION}")
    [[ "$SN_SPOOFING_PROT" == "n" ]] && lines+=("-M")
    lines+=("-t=${SN_MGMT_PORT}")
    [[ -n "$SN_COMMUNITY_FILE" ]] && lines+=("-c=${SN_COMMUNITY_FILE}")
    [[ -n "$SN_AUTO_IP" ]] && lines+=("-a=${SN_AUTO_IP}")
    local i
    for (( i=0; i<SN_VERBOSITY; i++ )); do lines+=("-v"); done
    lines+=("-f")

    printf '%s\n' "${lines[@]}" > "$conf_path"
}

generate_supernode_plist() {
    local plist_path="$1"

    local x_federation x_community_file x_auto_ip
    x_federation=$(xml_escape "$SN_FEDERATION")
    x_community_file=$(xml_escape "$SN_COMMUNITY_FILE")
    x_auto_ip=$(xml_escape "$SN_AUTO_IP")

    local args=""
    args+="        <string>${SUPERNODE_BIN}</string>\n"
    args+="        <string>-p</string>\n        <string>${SN_PORT}</string>\n"
    [[ -n "$SN_FEDERATION" ]] && args+="        <string>-F</string>\n        <string>${x_federation}</string>\n"
    [[ "$SN_SPOOFING_PROT" == "n" ]] && args+="        <string>-M</string>\n"
    args+="        <string>-t</string>\n        <string>${SN_MGMT_PORT}</string>\n"
    [[ -n "$SN_COMMUNITY_FILE" ]] && args+="        <string>-c</string>\n        <string>${x_community_file}</string>\n"
    [[ -n "$SN_AUTO_IP" ]] && args+="        <string>-a</string>\n        <string>${x_auto_ip}</string>\n"
    local i
    for (( i=0; i<SN_VERBOSITY; i++ )); do args+="        <string>-v</string>\n"; done
    args+="        <string>-f</string>\n"

    cat > "$plist_path" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SN_PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
$(printf '%b' "$args" | sed '/^$/d')
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ProcessType</key>
    <string>Background</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>ExitTimeOut</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>/var/log/n2n-supernode.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/n2n-supernode.log</string>
</dict>
</plist>
PLISTEOF
}

do_supernode() {
    local subcmd="${1:-}"
    detect_binaries

    case "$subcmd" in
        create|setup)
            do_supernode_create ;;
        status|show)
            do_supernode_status ;;
        start)
            do_supernode_start ;;
        stop)
            do_supernode_stop ;;
        restart)
            do_supernode_stop
            sleep 1
            do_supernode_start
            ;;
        delete|remove)
            do_supernode_delete ;;
        *)
            print_header "Supernode Management"

            local sn_conf="$CONFIG_DIR/supernode.conf"
            if [[ -f "$sn_conf" ]]; then
                do_supernode_status || true
                echo ""
                local sn_action
                if ! ask_choice "Action" sn_action \
                    "Edit configuration" \
                    "Start" \
                    "Stop" \
                    "Restart" \
                    "Delete" \
                    "Back"; then
                    return
                fi
                case $sn_action in
                    1) do_supernode_create ;;
                    2) do_supernode_start ;;
                    3) do_supernode_stop ;;
                    4) do_supernode_stop; sleep 1; do_supernode_start ;;
                    5) do_supernode_delete ;;
                    6) return ;;
                esac
            else
                print_info "No supernode configured."
                echo ""
                if ask_yesno "Create one now?" "y"; then
                    do_supernode_create
                fi
            fi
            ;;
    esac
}

do_supernode_create() {
    if [[ -z "$SUPERNODE_BIN" ]]; then
        print_status "$SYM_FAIL" "supernode binary not found. Run: cd ~/.mac2n && ./build.sh all"
        return 1
    fi

    print_section "Configure Supernode"

    local sn_conf="$CONFIG_DIR/supernode.conf"
    if [[ -f "$sn_conf" ]]; then
        parse_supernode_conf "$sn_conf"
        print_info "Existing config loaded. Press Enter to keep current values."
    fi

    while true; do
        ask "Listen port" "$SN_PORT" SN_PORT
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_port "$SN_PORT" "Listen port" 2>&1); then
            if ! check_port_available "$SN_PORT"; then
                printf "  ${YELLOW}  ↳ Warning: port %s appears to be in use${RESET}\n" "$SN_PORT"
                if ask_yesno "Use it anyway?" "n"; then break; fi
            else
                break
            fi
        else
            printf "  ${RED}  ↳ %s${RESET}\n" "$err"
        fi
    done

    echo ""
    ask "Federation name" "$SN_FEDERATION" SN_FEDERATION

    if ask_yesno "Enable MAC/IP spoofing protection?" "${SN_SPOOFING_PROT}"; then
        SN_SPOOFING_PROT="y"
    else
        SN_SPOOFING_PROT="n"
    fi

    while true; do
        ask "Management port" "$SN_MGMT_PORT" SN_MGMT_PORT
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_port "$SN_MGMT_PORT" "Management port" 2>&1); then
            if [[ "$SN_MGMT_PORT" == "$SN_PORT" ]]; then
                printf "  ${RED}  ↳ Must differ from listen port (%s)${RESET}\n" "$SN_PORT"
            else
                local edge_conflict
                edge_conflict=$(check_mgmt_port_conflict "$SN_MGMT_PORT" "")
                if [[ -n "$edge_conflict" ]]; then
                    printf "  ${YELLOW}  ↳ Warning: port %s conflicts with edge instance '%s'${RESET}\n" "$SN_MGMT_PORT" "$edge_conflict"
                    if ask_yesno "Use it anyway?" "n"; then break; fi
                elif ! check_port_available "$SN_MGMT_PORT"; then
                    printf "  ${YELLOW}  ↳ Warning: port %s appears to be in use${RESET}\n" "$SN_MGMT_PORT"
                    if ask_yesno "Use it anyway?" "n"; then break; fi
                else
                    break
                fi
            fi
        else
            printf "  ${RED}  ↳ %s${RESET}\n" "$err"
        fi
    done

    # Review
    print_box "Supernode" \
        "Listen Port:   ${SN_PORT}" \
        "Federation:    ${SN_FEDERATION:-"(default)"}" \
        "Mgmt Port:     ${SN_MGMT_PORT}" \
        "Spoofing Prot: $(if [[ "$SN_SPOOFING_PROT" == "y" ]]; then echo "enabled"; else echo "disabled"; fi)"

    echo ""
    if ! ask_yesno "Save this configuration?" "y"; then
        print_status "$SYM_WARN" "Aborted."
        return
    fi

    mkdir -p "$CONFIG_DIR"
    generate_supernode_conf "$sn_conf"
    chmod 600 "$sn_conf"
    print_status "$SYM_OK" "Config saved: $sn_conf"

    echo ""
    if ask_yesno "Install as LaunchDaemon?" "y"; then
        local sn_plist="${PLIST_DIR}/${SN_PLIST_LABEL}.plist"

        if launchd_label_loaded "$SN_PLIST_LABEL"; then
            sudo launchctl unload "$sn_plist" 2>/dev/null || true
        fi

        local tmp_plist
        tmp_plist=$(mktemp /tmp/n2n-sn-plist.XXXXXX)
        _CLEANUP_FILES+=("$tmp_plist")
        chmod 600 "$tmp_plist"
        generate_supernode_plist "$tmp_plist"

        sudo cp "$tmp_plist" "$sn_plist"
        sudo chown root:wheel "$sn_plist"
        sudo chmod 600 "$sn_plist"
        rm -f "$tmp_plist"
        print_status "$SYM_OK" "Installed: $sn_plist"

        install_logrotation

        echo ""
        if ask_yesno "Start supernode now?" "y"; then
            do_supernode_start
        fi
    fi
}

do_supernode_status() {
    print_section "Supernode Status"

    local sn_conf="$CONFIG_DIR/supernode.conf"
    if [[ ! -f "$sn_conf" ]]; then
        print_status "$SYM_DOT" "No supernode configured."
        return
    fi

    if ! parse_supernode_conf "$sn_conf"; then
        print_status "$SYM_FAIL" "Could not read supernode config."
        return 1
    fi

    local sn_plist="${PLIST_DIR}/${SN_PLIST_LABEL}.plist"

    if launchd_label_loaded "$SN_PLIST_LABEL"; then
        local pid
        pid=$(_launchctl_pid_from_label "$SN_PLIST_LABEL" 2>/dev/null) || true
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_status "$SYM_OK" "Running (PID $pid)"
        else
            print_status "$SYM_WARN" "Loaded but not running"
        fi
    elif [[ -f "$sn_plist" ]]; then
        print_status "$SYM_DOT" "Installed but not loaded"
    else
        print_status "$SYM_DOT" "Config only"
    fi

    print_box "Supernode" \
        "Listen Port:   ${SN_PORT}" \
        "Federation:    ${SN_FEDERATION:-"(default)"}" \
        "Mgmt Port:     ${SN_MGMT_PORT}" \
        "Spoofing Prot: $(if [[ "$SN_SPOOFING_PROT" == "y" ]]; then echo "enabled"; else echo "disabled"; fi)"
}

do_supernode_start() {
    local sn_plist="${PLIST_DIR}/${SN_PLIST_LABEL}.plist"

    if [[ ! -f "$sn_plist" ]]; then
        print_status "$SYM_FAIL" "Supernode daemon not installed."
        return 1
    fi

    if ! launchd_label_loaded "$SN_PLIST_LABEL"; then
        sudo launchctl load "$sn_plist"
    fi
    sudo launchctl start "$SN_PLIST_LABEL"
    sleep 1

    local pid
    pid=$(_launchctl_pid_from_label "$SN_PLIST_LABEL" 2>/dev/null) || true
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print_status "$SYM_OK" "Supernode started (PID $pid)"
    else
        print_status "$SYM_WARN" "Start command sent. Check: tail -f /var/log/n2n-supernode.log"
    fi
}

do_supernode_stop() {
    local sn_plist="${PLIST_DIR}/${SN_PLIST_LABEL}.plist"
    local stopped=false

    if launchd_label_loaded "$SN_PLIST_LABEL"; then
        sudo launchctl stop "$SN_PLIST_LABEL" 2>/dev/null || true
        sudo launchctl unload "$sn_plist" 2>/dev/null || true
        stopped=true
    else
        sudo launchctl unload "$sn_plist" 2>/dev/null || true
    fi

    local pid
    pid=$(_launchctl_pid_from_label "$SN_PLIST_LABEL" 2>/dev/null) || true
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        sudo kill "$pid" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$pid" 2>/dev/null; then
            sudo kill -9 "$pid" 2>/dev/null || true
        fi
        stopped=true
    fi

    if $stopped; then
        print_status "$SYM_OK" "Supernode stopped."
    else
        print_status "$SYM_DOT" "Supernode not running."
    fi
}

do_supernode_delete() {
    print_section "Delete Supernode"

    if ! ask_yesno "Remove supernode configuration and daemon?" "n"; then
        print_status "$SYM_DOT" "Aborted."
        return
    fi

    do_supernode_stop 2>/dev/null || true

    local sn_plist="${PLIST_DIR}/${SN_PLIST_LABEL}.plist"
    sudo rm -f "$sn_plist" 2>/dev/null || true
    rm -f "$CONFIG_DIR/supernode.conf" 2>/dev/null || true

    if [[ -f "/var/log/n2n-supernode.log" ]]; then
        if ask_yesno "Remove supernode log?" "y"; then
            sudo rm -f "/var/log/n2n-supernode.log"
        fi
    fi

    print_status "$SYM_OK" "Supernode removed."
}

# ── Legacy Migration ─────────────────────────────────────────────────────────

detect_legacy_instance() {
    local legacy_conf="$CONFIG_DIR/edge.conf"
    local legacy_plist="${PLIST_DIR}/org.ntop.n2n-edge.plist"

    if [[ -f "$legacy_conf" ]] || [[ -f "$legacy_plist" ]]; then
        return 0
    fi
    return 1
}

do_migrate() {
    detect_binaries

    print_header "Migrate Legacy Configuration"

    local legacy_conf="$CONFIG_DIR/edge.conf"
    local legacy_plist="${PLIST_DIR}/org.ntop.n2n-edge.plist"
    local found=false

    if [[ -f "$legacy_conf" ]]; then
        found=true
        print_status "$SYM_DOT" "Found: $legacy_conf"
    fi
    if [[ -f "$legacy_plist" ]]; then
        found=true
        print_status "$SYM_DOT" "Found: $legacy_plist"
    fi

    if ! $found; then
        print_status "$SYM_OK" "No legacy configuration found."
        return
    fi

    echo ""
    print_info "Your old single-instance setup will be migrated to the new"
    print_info "multi-instance format. You'll choose a name for the instance."
    echo ""

    local migrate_name="default"
    ask "Instance name for migrated config" "$migrate_name" migrate_name

    local err
    if ! err=$(validate_instance_name "$migrate_name" 2>&1); then
        print_status "$SYM_FAIL" "$err"
        return
    fi
    if instance_exists "$migrate_name"; then
        print_status "$SYM_FAIL" "Instance '$migrate_name' already exists."
        return
    fi

    if [[ -f "$legacy_conf" ]]; then
        local conf_dir
        conf_dir="$(instance_config_dir "$migrate_name")"
        mkdir -p "$conf_dir"
        chmod 700 "$conf_dir"
        cp "$legacy_conf" "$(instance_config_path "$migrate_name")"
        chmod 600 "$(instance_config_path "$migrate_name")"
        print_status "$SYM_OK" "Migrated config to: $(instance_config_path "$migrate_name")"

        if ask_yesno "Remove old config file?" "y"; then
            rm -f "$legacy_conf"
            print_status "$SYM_OK" "Removed: $legacy_conf"
        fi
    fi

    if [[ -f "$legacy_plist" ]]; then
        # Stop/unload old daemon
        if launchd_label_loaded "org.ntop.n2n-edge"; then
            sudo launchctl unload "$legacy_plist" 2>/dev/null || true
            print_status "$SYM_OK" "Unloaded legacy daemon"
        fi

        if [[ -n "$EDGE_BIN" ]] && instance_exists "$migrate_name"; then
            if parse_edge_conf "$(instance_config_path "$migrate_name")"; then
                install_instance_daemon "$migrate_name"
            else
                print_status "$SYM_WARN" "Could not read migrated config. Daemon not installed."
            fi
        elif ! instance_exists "$migrate_name"; then
            print_status "$SYM_WARN" "Legacy plist found but no config file to migrate."
            print_info "The old daemon will be removed. Use '$(basename "$0") create $migrate_name' to set up a new instance."
        fi

        if ask_yesno "Remove old plist file?" "y"; then
            sudo rm -f "$legacy_plist"
            print_status "$SYM_OK" "Removed: $legacy_plist"
        fi
    fi

    echo ""
    print_status "$SYM_OK" "${BOLD}Migration complete. Instance '${migrate_name}' is ready.${RESET}"
    print_info "Start with: $(basename "$0") start $migrate_name"
}

# ── Global Status ────────────────────────────────────────────────────────────

do_status() {
    detect_binaries

    if ! sudo -n true 2>/dev/null; then
        print_info "Tip: run with sudo cached for accurate daemon status"
    fi

    print_header "N2N VPN Status"

    # Binaries
    printf "  ${WHITE}Binaries${RESET}\n"
    if [[ -n "$EDGE_BIN" ]]; then
        print_status "$SYM_OK" "edge: ${EDGE_BIN}"
    else
        print_status "$SYM_FAIL" "edge: not found"
    fi
    if [[ -n "$SUPERNODE_BIN" ]]; then
        print_status "$SYM_OK" "supernode: ${SUPERNODE_BIN}"
    else
        print_status "$SYM_FAIL" "supernode: not found"
    fi

    # Supernode
    echo ""
    printf "  ${WHITE}Supernode${RESET}\n"
    local sn_conf="$CONFIG_DIR/supernode.conf"
    if [[ -f "$sn_conf" ]] && parse_supernode_conf "$sn_conf"; then
        if launchd_label_loaded "$SN_PLIST_LABEL"; then
            local pid
            pid=$(_launchctl_pid_from_label "$SN_PLIST_LABEL" 2>/dev/null) || true
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                print_status "$SYM_OK" "Running (PID $pid) on port ${SN_PORT}"
            else
                print_status "$SYM_WARN" "Loaded but not running (port ${SN_PORT})"
            fi
        else
            print_status "$SYM_DOT" "Configured but not running (port ${SN_PORT})"
        fi
    else
        print_status "$SYM_DOT" "Not configured"
    fi

    # Edge instances
    echo ""
    printf "  ${WHITE}Edge Instances${RESET}\n"

    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} == 0 )); then
        print_status "$SYM_DOT" "No instances configured"
    else
        local name
        for name in "${names[@]}"; do
            if ! parse_edge_conf "$(instance_config_path "$name")"; then continue; fi

            if instance_is_running "$name"; then
                local pid
                pid=$(instance_pid "$name")
                print_status "$SYM_OK" "${BOLD}${name}${RESET}: ${GREEN}running${RESET} (PID ${pid:-?}) — ${EDGE_COMMUNITY} @ ${EDGE_IP} → ${EDGE_SUPERNODE}"
            elif instance_is_loaded "$name"; then
                print_status "$SYM_WARN" "${BOLD}${name}${RESET}: ${YELLOW}loaded (not running)${RESET} — ${EDGE_COMMUNITY} @ ${EDGE_IP}"
            elif instance_plist_installed "$name"; then
                print_status "$SYM_DOT" "${BOLD}${name}${RESET}: installed — ${EDGE_COMMUNITY} @ ${EDGE_IP}"
            else
                print_status "$SYM_DOT" "${BOLD}${name}${RESET}: config only — ${EDGE_COMMUNITY} @ ${EDGE_IP}"
            fi
        done
    fi

    # Network interfaces
    echo ""
    printf "  ${WHITE}Network (utun interfaces)${RESET}\n"
    local utun_found=false
    while IFS= read -r iface; do
        [[ "$iface" =~ ^utun ]] || continue
        local addr
        addr=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
        if [[ -n "$addr" ]]; then
            print_status "$SYM_OK" "${iface}: ${addr}"
            utun_found=true
        fi
    done < <(ifconfig -l 2>/dev/null | tr ' ' '\n')
    if ! $utun_found; then
        print_status "$SYM_DOT" "No active utun interfaces with IP"
    fi

    # Legacy check
    if detect_legacy_instance 2>/dev/null; then
        echo ""
        printf "  ${YELLOW}${BOLD}Legacy Setup Detected${RESET}\n"
        print_info "You have an old single-instance config. Run '$(basename "$0") migrate' to upgrade."
    fi

    echo ""
}

# ── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    detect_binaries

    print_header "Uninstall mac2n"

    local found=false

    # Check for instances
    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} > 0 )); then
        found=true
        print_status "$SYM_DOT" "${#names[@]} edge instance(s): ${names[*]}"
    fi

    # Supernode
    if [[ -f "$CONFIG_DIR/supernode.conf" ]]; then
        found=true
        print_status "$SYM_DOT" "Supernode configuration"
    fi
    if [[ -f "${PLIST_DIR}/${SN_PLIST_LABEL}.plist" ]]; then
        found=true
        print_status "$SYM_DOT" "Supernode LaunchDaemon"
    fi

    # Legacy
    if [[ -f "$CONFIG_DIR/edge.conf" ]]; then
        found=true
        print_status "$SYM_DOT" "Legacy edge config"
    fi
    if [[ -f "${PLIST_DIR}/org.ntop.n2n-edge.plist" ]]; then
        found=true
        print_status "$SYM_DOT" "Legacy edge LaunchDaemon"
    fi

    if ! $found; then
        print_status "$SYM_OK" "Nothing to uninstall."
        return
    fi

    echo ""
    printf "  ${RED}${BOLD}This will remove ALL n2n services and configuration.${RESET}\n"
    if ! ask_yesno "Are you sure?" "n"; then
        print_status "$SYM_DOT" "Aborted."
        return
    fi

    # Stop and remove all edge instances
    local name
    for name in ${names[@]+"${names[@]}"}; do
        if instance_is_loaded "$name"; then
            local label
            label="$(instance_plist_label "$name")"
            sudo launchctl stop "$label" 2>/dev/null || true
            local plist_path
            plist_path="$(instance_plist_path "$name")"
            sudo launchctl unload "$plist_path" 2>/dev/null || true
        elif instance_is_running "$name"; then
            local pid
            pid=$(instance_pid "$name")
            [[ -n "$pid" ]] && sudo kill "$pid" 2>/dev/null || true
        fi
        if instance_plist_installed "$name"; then
            sudo rm -f "$(instance_plist_path "$name")"
        fi
        print_status "$SYM_OK" "Removed edge instance: $name"
    done

    # Stop and remove supernode
    if launchd_label_loaded "$SN_PLIST_LABEL"; then
        sudo launchctl stop "$SN_PLIST_LABEL" 2>/dev/null || true
        sudo launchctl unload "${PLIST_DIR}/${SN_PLIST_LABEL}.plist" 2>/dev/null || true
    fi
    sudo rm -f "${PLIST_DIR}/${SN_PLIST_LABEL}.plist" 2>/dev/null || true
    print_status "$SYM_OK" "Removed supernode daemon"

    # Remove legacy
    if [[ -f "${PLIST_DIR}/org.ntop.n2n-edge.plist" ]]; then
        sudo launchctl unload "${PLIST_DIR}/org.ntop.n2n-edge.plist" 2>/dev/null || true
        sudo rm -f "${PLIST_DIR}/org.ntop.n2n-edge.plist"
        print_status "$SYM_OK" "Removed legacy edge daemon"
    fi

    # Remove log rotation daemon
    remove_logrotation
    print_status "$SYM_OK" "Removed log rotation daemon"

    # Remove firewall exceptions for binaries (detected + default paths)
    local fw="/usr/libexec/ApplicationFirewall/socketfilterfw"
    if [[ -x "$fw" ]]; then
        local -a fw_bins=(/usr/local/sbin/edge /usr/local/sbin/supernode)
        [[ -n "$EDGE_BIN" ]] && fw_bins+=("$EDGE_BIN")
        [[ -n "$SUPERNODE_BIN" ]] && fw_bins+=("$SUPERNODE_BIN")
        local seen="" bin
        for bin in "${fw_bins[@]}"; do
            [[ "$seen" == *"|${bin}|"* ]] && continue
            seen="${seen}|${bin}|"
            [[ -f "$bin" ]] && sudo "$fw" --remove "$bin" 2>/dev/null || true
        done
        print_status "$SYM_OK" "Removed firewall exceptions"
    fi

    # Remove all config
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        print_status "$SYM_OK" "Removed config directory: $CONFIG_DIR"
    fi

    # Remove logs (including rotated archives)
    if ask_yesno "Remove all n2n log files?" "y"; then
        sudo rm -f /var/log/n2n-edge*.log /var/log/n2n-supernode.log /var/log/n2n-*.log.*.gz 2>/dev/null || true
        print_status "$SYM_OK" "Removed log files"
    fi

    echo ""
    print_info "Note: n2n binaries were not removed. To remove them:"
    print_info "  sudo rm -f /usr/local/sbin/edge /usr/local/sbin/supernode"
    print_info "Or run: ~/.mac2n/install.sh --uninstall"
    echo ""
    print_status "$SYM_OK" "${BOLD}Uninstall complete.${RESET}"
}

# ── Self-Update ───────────────────────────────────────────────────────────────

do_update() {
    detect_binaries

    if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
        print_status "$SYM_FAIL" "Not a git checkout — cannot self-update."
        print_info "Re-install with: bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/mchsk/mac2n/main/install.sh)\""
        return 1
    fi

    print_header "Update mac2n"

    cd "$SCRIPT_DIR"

    local current_version="$VERSION"
    print_info "Current version: v${current_version}"

    if ! git fetch --quiet origin 2>/dev/null; then
        print_status "$SYM_FAIL" "Could not reach remote — check your internet connection."
        return 1
    fi

    local behind
    behind=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
    if (( behind == 0 )); then
        print_status "$SYM_OK" "Already up to date."
        return
    fi

    print_info "$behind new commit(s) available."
    echo ""

    if ! ask_yesno "Pull updates and rebuild?" "y"; then
        print_status "$SYM_DOT" "Aborted."
        return
    fi

    if ! git pull --ff-only --quiet 2>&1; then
        print_status "$SYM_FAIL" "git pull failed — you may have local changes. Try: git stash && mac2n self-update"
        return 1
    fi

    if ! git submodule update --init --quiet 2>&1; then
        print_status "$SYM_FAIL" "Submodule update failed."
        return 1
    fi

    print_status "$SYM_OK" "Source updated."

    echo ""
    if ask_yesno "Rebuild n2n from updated source?" "y"; then
        ensure_sudo
        if ! bash ./build.sh all 2>&1; then
            print_status "$SYM_FAIL" "Build failed — check output above."
            return 1
        fi
    fi

    local new_version
    new_version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
    echo ""
    print_status "$SYM_OK" "${BOLD}Updated to v${new_version}.${RESET}"
}

# ── Interactive Menu ─────────────────────────────────────────────────────────

do_interactive_menu() {
    detect_binaries

    # Check for legacy on first run
    if detect_legacy_instance 2>/dev/null; then
        echo ""
        printf "  ${YELLOW}${BOLD}Legacy single-instance setup detected.${RESET}\n"
        if ask_yesno "Migrate to multi-instance format now?" "y"; then
            do_migrate
            echo ""
        fi
    fi

    while true; do
        print_header "mac2n" "N2N VPN for macOS · native utun interface"

        # Quick status
        local names=()
        while IFS= read -r name; do
            [[ -n "$name" ]] && names+=("$name")
        done < <(list_instance_names)

        if (( ${#names[@]} > 0 )); then
            local running=0
            local name
            for name in "${names[@]}"; do
                if instance_is_running "$name"; then running=$((running + 1)); fi
            done
            printf "  ${DIM}%d instance(s), %d running${RESET}\n\n" "${#names[@]}" "$running"
        fi

        printf "    ${WHITE}1)${RESET} Create new edge instance\n"
        printf "    ${WHITE}2)${RESET} List all instances\n"
        printf "    ${WHITE}3)${RESET} Show instance details\n"
        printf "    ${WHITE}4)${RESET} Edit instance\n"
        printf "    ${WHITE}5)${RESET} Delete instance\n"
        printf "    ${WHITE}6)${RESET} Start / Stop / Restart\n"
        printf "    ${WHITE}7)${RESET} View logs\n"
        printf "    ${WHITE}8)${RESET} Supernode management\n"
        printf "    ${WHITE}9)${RESET} Full status overview\n"
        printf "    ${WHITE}0)${RESET} Exit\n"
        echo ""

        local choice
        printf "  ${SYM_ARROW} ${BOLD}Select action${RESET} ${DIM}[0-9]${RESET}: "
        if ! read -r choice; then
            echo ""
            print_status "$SYM_OK" "Goodbye."
            echo ""
            exit 0
        fi

        case "$choice" in
            1) do_create || true ;;
            2) do_list || true ;;
            3) do_show || true ;;
            4) do_edit || true ;;
            5) do_delete || true ;;
            6)
                echo ""
                local svc_action
                ask_choice "Service action" svc_action \
                    "Start instance" \
                    "Stop instance" \
                    "Restart instance" \
                    "Start all" \
                    "Stop all" \
                    "Restart all" \
                    "Back"
                case $svc_action in
                    1) do_start || true ;;
                    2) do_stop || true ;;
                    3) do_restart || true ;;
                    4) do_start "--all" || true ;;
                    5) do_stop "--all" || true ;;
                    6) do_restart "--all" || true ;;
                    7) ;;
                esac
                ;;
            7) do_logs || true ;;
            8) do_supernode || true ;;
            9) do_status || true ;;
            0|q|Q|exit)
                echo ""
                print_status "$SYM_OK" "Goodbye."
                echo ""
                exit 0
                ;;
            *)
                printf "  ${RED}Invalid choice.${RESET}\n"
                sleep 1
                ;;
        esac

        echo ""
        printf "  ${DIM}Press Enter to return to menu...${RESET}"
        read -r || true
    done
}

# ── Help ─────────────────────────────────────────────────────────────────────

do_help() {
    cat <<EOF

  $(printf "${BOLD}mac2n — N2N VPN for macOS${RESET}") $(printf "${DIM}v${VERSION}${RESET}")

  $(printf "${WHITE}Usage:${RESET}")  $(basename "$0") <command> [args]

  $(printf "${WHITE}Instance Management:${RESET}")
    create [name]       Create a new edge instance (interactive wizard)
    list                List all configured instances with status
    show <name>         Show detailed info for an instance
    edit <name>         Edit an existing instance configuration
    delete <name>       Delete an instance (stops if running)

  $(printf "${WHITE}Service Control:${RESET}")
    start <name|--all>  Start instance(s)
    stop <name|--all>   Stop instance(s)
    restart <name|--all> Restart instance(s)
    logs <name>         Tail logs for an instance

  $(printf "${WHITE}Supernode:${RESET}")
    supernode [create|status|start|stop|restart|delete]

  $(printf "${WHITE}Other:${RESET}")
    status              Show full status overview
    self-update         Pull latest source and rebuild
    migrate             Migrate legacy single-instance setup
    uninstall           Remove all n2n services and configuration
    help                Show this help
    --version, -V       Print version and exit

  $(printf "${WHITE}Examples:${RESET}")
    $(basename "$0")                  Interactive menu
    $(basename "$0") create home      Create instance named "home"
    $(basename "$0") list             Show all instances
    $(basename "$0") start home       Start the "home" instance
    $(basename "$0") start --all      Start all instances
    $(basename "$0") edit home        Edit the "home" instance
    $(basename "$0") status           Full system status

EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    case "${1:-menu}" in
        menu|wizard|configure|setup)
            do_interactive_menu
            ;;
        create|new|add)
            do_create "${2:-}"
            ;;
        list|ls)
            do_list
            ;;
        show|info|inspect)
            do_show "${2:-}"
            ;;
        edit|modify)
            do_edit "${2:-}"
            ;;
        delete|remove|rm)
            do_delete "${2:-}"
            ;;
        start)
            do_start "${2:-}"
            ;;
        stop)
            do_stop "${2:-}"
            ;;
        restart)
            do_restart "${2:-}"
            ;;
        logs|log|tail)
            do_logs "${2:-}"
            ;;
        status)
            do_status
            ;;
        supernode|sn)
            do_supernode "${2:-}"
            ;;
        self-update|upgrade)
            do_update
            ;;
        migrate)
            do_migrate
            ;;
        uninstall)
            do_uninstall
            ;;
        help|-h|--help)
            do_help
            ;;
        --version|-V)
            echo "mac2n v${VERSION}"
            ;;
        *)
            printf "${RED}Unknown command: %s${RESET}\n" "$1" >&2
            do_help
            exit 1
            ;;
    esac
}

main "$@"
