#!/usr/bin/env bash
# lib/edge_model.sh — Edge config model: defaults, parse, unified render
# Single source of truth for edge flag mapping (eliminates triple duplication).
# Depends on: lib/core.sh, lib/validate.sh, lib/instance.sh

[[ -n "${_LIB_EDGE_MODEL_LOADED:-}" ]] && return 0
[[ -n "${_LIB_CORE_LOADED:-}" ]] || { echo "lib/edge_model.sh: lib/core.sh must be loaded first" >&2; exit 1; }
_LIB_EDGE_MODEL_LOADED=1

# ── Edge Config Globals ─────────────────────────────────────────────────────

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

# ── Parse ───────────────────────────────────────────────────────────────────

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
            -H)   ;;
            -f)   ;;
        esac
    done < "$conf_path"
}

# ── Unified Argument Model ──────────────────────────────────────────────────
# _build_edge_args populates EDGE_ARGS with (flag, value) pairs.
# All three renderers consume this single model.

_build_edge_args() {
    EDGE_ARGS=()
    EDGE_ARGS+=("-c" "$EDGE_COMMUNITY")
    EDGE_ARGS+=("-l" "$EDGE_SUPERNODE")
    [[ -n "$EDGE_SUPERNODE2" ]] && EDGE_ARGS+=("-l" "$EDGE_SUPERNODE2")
    EDGE_ARGS+=("-a" "static:${EDGE_IP}/${EDGE_CIDR}")
    [[ -n "$EDGE_KEY" ]] && EDGE_ARGS+=("-k" "$EDGE_KEY")
    [[ "$EDGE_CIPHER" != "3" ]] && EDGE_ARGS+=("-A${EDGE_CIPHER}" "")
    [[ "$EDGE_MTU" != "1290" ]] && EDGE_ARGS+=("-M" "$EDGE_MTU")
    [[ "$EDGE_ROUTING" == "y" ]] && EDGE_ARGS+=("-r" "")
    [[ "$EDGE_MULTICAST" == "y" ]] && EDGE_ARGS+=("-E" "")
    [[ -n "${EDGE_COMPRESSION:-}" ]] && EDGE_ARGS+=("-z${EDGE_COMPRESSION}" "")
    [[ -n "$EDGE_MAC" ]] && EDGE_ARGS+=("-m" "$EDGE_MAC")
    [[ "$EDGE_LOCAL_PORT" != "0" ]] && [[ -n "$EDGE_LOCAL_PORT" ]] && EDGE_ARGS+=("-p" "$EDGE_LOCAL_PORT")
    EDGE_ARGS+=("-t" "$EDGE_MGMT_PORT")
    [[ "$EDGE_SN_SELECT" == "rtt" ]] && EDGE_ARGS+=("--select-rtt" "")
    [[ "$EDGE_SN_SELECT" == "mac" ]] && EDGE_ARGS+=("--select-mac" "")
    [[ -n "$EDGE_DESCRIPTION" ]] && EDGE_ARGS+=("-I" "$EDGE_DESCRIPTION")
    [[ -n "$EDGE_ROUTES" ]] && EDGE_ARGS+=("-n" "$EDGE_ROUTES")
    local i
    for (( i=0; i<EDGE_VERBOSITY; i++ )); do EDGE_ARGS+=("-v" ""); done
    EDGE_ARGS+=("-f" "")
}

# ── Render: edge.conf ───────────────────────────────────────────────────────

generate_edge_conf() {
    local conf_path="$1"
    local instance_name="${2:-}"

    _build_edge_args

    {
        echo "# N2N Edge Configuration"
        [[ -n "$instance_name" ]] && echo "# Instance: ${instance_name}"
        echo "# Generated on $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        local i
        for (( i=0; i < ${#EDGE_ARGS[@]}; i+=2 )); do
            local flag="${EDGE_ARGS[i]}"
            local val="${EDGE_ARGS[i+1]}"
            if [[ -z "$val" ]]; then
                printf '%s\n' "$flag"
            else
                printf '%s=%s\n' "$flag" "$val"
            fi
        done
    } > "$conf_path"
}

# ── Render: LaunchDaemon plist ──────────────────────────────────────────────

generate_edge_plist() {
    local plist_path="$1"
    local instance_name="$2"
    local label
    label="$(instance_plist_label "$instance_name")"
    local log_path
    log_path="$(instance_log_path "$instance_name")"
    local conf_path
    conf_path="$(instance_config_path "$instance_name")"

    local args=""
    local net_wrapper="/opt/mac2n/bin/wait-for-network.sh"
    if [[ -x "$net_wrapper" ]]; then
        args+="        <string>${net_wrapper}</string>\n"
    fi
    args+="        <string>${EDGE_BIN}</string>\n"
    args+="        <string>$(xml_escape "$conf_path")</string>\n"

    cat > "$plist_path" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>

    <key>UserName</key>
    <string>root</string>

    <key>GroupName</key>
    <string>wheel</string>

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

    <key>Umask</key>
    <integer>77</integer>

    <key>StandardOutPath</key>
    <string>${log_path}</string>

    <key>StandardErrorPath</key>
    <string>${log_path}</string>
</dict>
</plist>
PLISTEOF

    sudo touch "$log_path"
    sudo chmod 640 "$log_path"
}

# ── Render: display command ─────────────────────────────────────────────────

build_edge_display_cmd() {
    _build_edge_args

    local cmd="sudo ${EDGE_BIN}"
    local i
    for (( i=0; i < ${#EDGE_ARGS[@]}; i+=2 )); do
        local flag="${EDGE_ARGS[i]}"
        local val="${EDGE_ARGS[i+1]}"
        if [[ "$flag" == "-k" ]]; then
            cmd+=" -k '***'"
        elif [[ -z "$val" ]]; then
            cmd+=" $flag"
        else
            cmd+=" $flag $val"
        fi
    done
    echo "$cmd"
}

# ── Display Helpers ─────────────────────────────────────────────────────────

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
