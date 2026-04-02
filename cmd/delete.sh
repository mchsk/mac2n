#!/usr/bin/env bash
# cmd/delete.sh — do_delete

[[ -n "${_CMD_DELETE_LOADED:-}" ]] && return 0
_CMD_DELETE_LOADED=1

do_delete() {
    local instance_name="${1:-}"
    acquire_lock
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

    if instance_is_running "$instance_name" || instance_is_loaded "$instance_name"; then
        print_status "$SYM_ARROW" "Stopping instance..."
        do_stop "$instance_name" 2>/dev/null || true
    fi

    if instance_plist_installed "$instance_name"; then
        local plist_path
        plist_path="$(instance_plist_path "$instance_name")"
        _launchctl_unload "$(instance_plist_label "$instance_name")" "$plist_path"
        sudo rm -f "$plist_path"
        print_status "$SYM_OK" "Removed LaunchDaemon"
    fi

    local conf_dir
    conf_dir="$(instance_config_dir "$instance_name")"
    rm -rf "$conf_dir"
    print_status "$SYM_OK" "Removed config directory"

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
