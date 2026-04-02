#!/usr/bin/env bash
# cmd/supernode_cmd.sh — do_supernode dispatcher + create/status/start/stop/delete

[[ -n "${_CMD_SUPERNODE_LOADED:-}" ]] && return 0
_CMD_SUPERNODE_LOADED=1

do_supernode() {
    local subcmd="${1:-}"
    acquire_lock
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
            _launchctl_unload "$SN_PLIST_LABEL" "$sn_plist"
        fi

        local tmp_plist
        tmp_plist=$(mktemp "${TMPDIR:-/tmp}/n2n-sn-plist.XXXXXX")
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
        _launchctl_load "$sn_plist"
    fi
    _launchctl_start "$SN_PLIST_LABEL"
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
        _launchctl_stop "$SN_PLIST_LABEL"
        _launchctl_unload "$SN_PLIST_LABEL" "$sn_plist"
        stopped=true
    else
        _launchctl_unload "$SN_PLIST_LABEL" "$sn_plist"
    fi

    local pid
    pid=$(_launchctl_pid_from_label "$SN_PLIST_LABEL" 2>/dev/null) || true
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        sudo kill "$pid" 2>/dev/null || true
        sleep 3
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
