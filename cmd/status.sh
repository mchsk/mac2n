#!/usr/bin/env bash
# cmd/status.sh — do_status, _preflight_health_check

[[ -n "${_CMD_STATUS_LOADED:-}" ]] && return 0
_CMD_STATUS_LOADED=1

_preflight_health_check() {
    detect_binaries

    local warned=false

    local plist
    for plist in "${PLIST_DIR}/${PLIST_PREFIX}."*.plist "${PLIST_DIR}/${SN_PLIST_LABEL}.plist"; do
        [[ -f "$plist" ]] || continue
        local bin_path
        bin_path=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist" 2>/dev/null || echo "")
        if [[ "$bin_path" == */wait-for-network.sh ]]; then
            bin_path=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$plist" 2>/dev/null || echo "")
        fi
        if [[ -n "$bin_path" ]] && [[ ! -x "$bin_path" ]]; then
            if ! $warned; then
                echo ""
                warned=true
            fi
            printf "  ${RED}${BOLD}WARNING: Binary missing!${RESET}\n"
            printf "  ${RED}Daemon references: %s${RESET}\n" "$bin_path"
            printf "  ${RED}This may happen after a macOS upgrade.${RESET}\n"
            echo ""
            printf "  ${YELLOW}Fix with:${RESET}  cd ~/.mac2n && ./build.sh all\n"
            printf "  ${YELLOW}Then:${RESET}      mac2n restart --all\n"
            echo ""
        fi
    done

    if [[ -n "$EDGE_BIN" ]] && [[ -x "$EDGE_BIN" ]]; then
        local linked_dylib
        linked_dylib=$(otool -L "$EDGE_BIN" 2>/dev/null | grep 'libcrypto\.' | head -1 | awk '{print $1}')
        if [[ -n "$linked_dylib" ]] && [[ ! -f "$linked_dylib" ]]; then
            if ! $warned; then
                echo ""
                warned=true
            fi
            printf "  ${YELLOW}WARNING: Bundled OpenSSL dylib missing at %s${RESET}\n" "$linked_dylib"
            printf "  ${YELLOW}Fix with:${RESET}  cd ~/.mac2n && ./build.sh install && ./build.sh harden\n"
            echo ""
        fi
    fi
}

do_status() {
    detect_binaries

    if ! sudo -n true 2>/dev/null; then
        print_info "Tip: run with sudo cached for accurate daemon status"
    fi

    print_header "N2N VPN Status"

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

    if detect_legacy_instance 2>/dev/null; then
        echo ""
        printf "  ${YELLOW}${BOLD}Legacy Setup Detected${RESET}\n"
        print_info "You have an old single-instance config. Run '$(basename "$0") migrate' to upgrade."
    fi

    echo ""
}
