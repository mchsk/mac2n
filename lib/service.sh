#!/usr/bin/env bash
# lib/service.sh — launchctl abstraction, daemon install/remove, logrotation
# Depends on: lib/core.sh, lib/instance.sh

[[ -n "${_LIB_SERVICE_LOADED:-}" ]] && return 0
[[ -n "${_LIB_CORE_LOADED:-}" ]] || { echo "lib/service.sh: lib/core.sh must be loaded first" >&2; exit 1; }
[[ -n "${_LIB_INSTANCE_LOADED:-}" ]] || { echo "lib/service.sh: lib/instance.sh must be loaded first" >&2; exit 1; }
_LIB_SERVICE_LOADED=1

# ── launchctl Abstraction ───────────────────────────────────────────────────

_launchctl_load() {
    local plist_path="$1"
    sudo launchctl bootstrap system "$plist_path" 2>/dev/null || \
        sudo launchctl load "$plist_path" 2>/dev/null || true
}

_launchctl_unload() {
    local label="$1"
    local plist_path="${2:-}"
    sudo launchctl bootout "system/$label" 2>/dev/null || \
        { [[ -n "$plist_path" ]] && sudo launchctl unload "$plist_path" 2>/dev/null; } || true
}

_launchctl_start() {
    local label="$1"
    sudo launchctl kickstart "system/$label" 2>/dev/null || \
        sudo launchctl start "$label" 2>/dev/null || true
}

_launchctl_stop() {
    local label="$1"
    sudo launchctl kill SIGTERM "system/$label" 2>/dev/null || \
        sudo launchctl stop "$label" 2>/dev/null || true
}

# ── Label/PID Queries ───────────────────────────────────────────────────────

launchd_label_loaded() {
    local label="$1"
    sudo -n launchctl print "system/$label" &>/dev/null && return 0
    sudo -n launchctl list "$label" &>/dev/null && return 0
    launchctl list "$label" &>/dev/null && return 0
    local plist_path="${PLIST_DIR}/${label}.plist"
    if [[ -f "$plist_path" ]]; then
        local bin_path
        bin_path=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist_path" 2>/dev/null || echo "")
        if [[ -n "$bin_path" ]]; then
            pgrep -f "$bin_path" &>/dev/null && return 0
        fi
    fi
    return 1
}

_launchctl_pid_from_label() {
    local label="$1" pid

    pid=$(sudo -n launchctl print "system/$label" 2>/dev/null \
        | awk '/pid =/ { print $NF; exit }') || true
    if [[ "${pid:-}" =~ ^[0-9]+$ ]] && (( pid > 0 )); then
        echo "$pid"
        return 0
    fi

    local output
    if output=$(sudo -n launchctl list "$label" 2>/dev/null); then
        pid=$(echo "$output" | awk '/"PID"/ { gsub(/[^0-9]/, "", $NF); print $NF }')
        if [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
            echo "$pid"
            return 0
        fi
    fi

    if output=$(launchctl list "$label" 2>/dev/null); then
        pid=$(echo "$output" | awk '/"PID"/ { gsub(/[^0-9]/, "", $NF); print $NF }')
        if [[ "${pid:-}" =~ ^[0-9]+$ ]]; then
            echo "$pid"
            return 0
        fi
    fi

    return 1
}

instance_is_loaded() {
    launchd_label_loaded "$(instance_plist_label "$1")"
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

# ── Management Port Allocation ──────────────────────────────────────────────

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

# ── Daemon Install ──────────────────────────────────────────────────────────

install_instance_daemon() {
    local instance_name="$1"

    if ! parse_edge_conf "$(instance_config_path "$instance_name")"; then
        print_status "$SYM_FAIL" "Could not read config for '$instance_name'. Aborting daemon install."
        return 1
    fi

    local plist_path
    plist_path="$(instance_plist_path "$instance_name")"

    _launchctl_unload "$(instance_plist_label "$instance_name")" "$plist_path"

    local tmp_plist
    tmp_plist=$(mktemp "${TMPDIR:-/tmp}/n2n-edge-plist.XXXXXX")
    _CLEANUP_FILES+=("$tmp_plist")
    chmod 600 "$tmp_plist"
    generate_edge_plist "$tmp_plist" "$instance_name"

    sudo cp "$tmp_plist" "$plist_path"
    sudo chown root:wheel "$plist_path"
    sudo chmod 644 "$plist_path"
    rm -f "$tmp_plist"

    print_status "$SYM_OK" "LaunchDaemon installed: $(instance_plist_label "$instance_name")"

    install_logrotation
}

# ── Log Rotation ────────────────────────────────────────────────────────────

install_logrotation() {
    local plist_path="${PLIST_DIR}/${LOGROTATE_LABEL}.plist"

    local system_rotate="/opt/mac2n/bin/n2n-logrotate.sh"
    local source_rotate="${SCRIPT_DIR}/n2n-logrotate.sh"
    if [[ -f "$source_rotate" ]]; then
        sudo mkdir -p "$(dirname "$system_rotate")"
        sudo cp "$source_rotate" "$system_rotate"
        sudo chmod 755 "$system_rotate"
    fi

    [[ -f "$plist_path" ]] && return 0

    if [[ ! -x "$system_rotate" ]]; then
        print_status "$SYM_WARN" "Log rotation script not found"
        return 1
    fi

    local tmp_plist
    tmp_plist=$(mktemp "${TMPDIR:-/tmp}/n2n-logrotate-plist.XXXXXX")
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
        <string>${system_rotate}</string>
    </array>

    <key>StartCalendarInterval</key>
    <array>
        <dict>
            <key>Hour</key><integer>0</integer>
            <key>Minute</key><integer>30</integer>
        </dict>
        <dict>
            <key>Hour</key><integer>6</integer>
            <key>Minute</key><integer>30</integer>
        </dict>
        <dict>
            <key>Hour</key><integer>12</integer>
            <key>Minute</key><integer>30</integer>
        </dict>
        <dict>
            <key>Hour</key><integer>18</integer>
            <key>Minute</key><integer>30</integer>
        </dict>
    </array>
</dict>
</plist>
LREOF

    sudo cp "$tmp_plist" "$plist_path"
    sudo chown root:wheel "$plist_path"
    sudo chmod 644 "$plist_path"
    _launchctl_load "$plist_path"
    rm -f "$tmp_plist"

    print_status "$SYM_OK" "Log rotation installed (every 6h, 5 MB threshold)"
}

remove_logrotation() {
    local plist_path="${PLIST_DIR}/${LOGROTATE_LABEL}.plist"
    if [[ -f "$plist_path" ]]; then
        _launchctl_unload "$LOGROTATE_LABEL" "$plist_path"
        sudo rm -f "$plist_path"
    fi
}
