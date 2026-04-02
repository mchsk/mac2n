#!/usr/bin/env bash
# cmd/show.sh — do_show, do_list

[[ -n "${_CMD_SHOW_LOADED:-}" ]] && return 0
_CMD_SHOW_LOADED=1

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

    review_edge_config "$instance_name"

    echo ""
    printf "  ${WHITE}Files${RESET}\n"
    print_info "  Config: $(instance_config_path "$instance_name")"
    if instance_plist_installed "$instance_name"; then
        print_info "  Plist:  $(instance_plist_path "$instance_name")"
    fi
    print_info "  Log:    $(instance_log_path "$instance_name")"

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
