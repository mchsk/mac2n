#!/usr/bin/env bash
# cmd/service_ctl.sh — do_start/stop/restart + _all variants, do_logs

[[ -n "${_CMD_SERVICE_CTL_LOADED:-}" ]] && return 0
_CMD_SERVICE_CTL_LOADED=1

do_start() {
    local instance_name="${1:-}"
    acquire_lock
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

    local label
    label="$(instance_plist_label "$instance_name")"
    if ! instance_is_loaded "$instance_name"; then
        _launchctl_load "$plist_path"
    fi
    _launchctl_start "$label"

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
    acquire_lock
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
        _launchctl_stop "$label"
        _launchctl_unload "$label" "$plist_path"
        stopped=true
    else
        _launchctl_unload "$label" "$plist_path"
    fi

    local pid
    pid=$(instance_pid "$instance_name")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        sudo kill "$pid" 2>/dev/null || true
        sleep 3
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
    acquire_lock

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
