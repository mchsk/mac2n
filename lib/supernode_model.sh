#!/usr/bin/env bash
# lib/supernode_model.sh — Supernode config model: defaults, parse, generate
# Depends on: lib/core.sh, lib/validate.sh

[[ -n "${_LIB_SUPERNODE_MODEL_LOADED:-}" ]] && return 0
[[ -n "${_LIB_CORE_LOADED:-}" ]] || { echo "lib/supernode_model.sh: lib/core.sh must be loaded first" >&2; exit 1; }
_LIB_SUPERNODE_MODEL_LOADED=1

# ── Supernode Config Globals ────────────────────────────────────────────────

SN_PORT="7777"
SN_MGMT_PORT="5645"
SN_FEDERATION=""
SN_COMMUNITY_FILE=""
SN_AUTO_IP=""
SN_VERBOSITY="0"
SN_SPOOFING_PROT="y"

# ── Parse ───────────────────────────────────────────────────────────────────

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

# ── Generate conf ───────────────────────────────────────────────────────────

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

# ── Generate plist ──────────────────────────────────────────────────────────

generate_supernode_plist() {
    local plist_path="$1"
    local sn_conf_path="$CONFIG_DIR/supernode.conf"

    local args=""
    local net_wrapper="/opt/mac2n/bin/wait-for-network.sh"
    if [[ -x "$net_wrapper" ]]; then
        args+="        <string>${net_wrapper}</string>\n"
    fi
    args+="        <string>${SUPERNODE_BIN}</string>\n"
    args+="        <string>$(xml_escape "$sn_conf_path")</string>\n"

    cat > "$plist_path" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SN_PLIST_LABEL}</string>

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
    <string>/var/log/n2n-supernode.log</string>

    <key>StandardErrorPath</key>
    <string>/var/log/n2n-supernode.log</string>
</dict>
</plist>
PLISTEOF

    sudo touch /var/log/n2n-supernode.log
    sudo chmod 640 /var/log/n2n-supernode.log
}
