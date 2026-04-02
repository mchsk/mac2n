#!/usr/bin/env bash
# cmd/edit.sh — do_edit, configure_edge, configure_edge_advanced, edit_*_settings

[[ -n "${_CMD_EDIT_LOADED:-}" ]] && return 0
_CMD_EDIT_LOADED=1

# ── Interactive Configuration Flows ─────────────────────────────────────────

configure_edge() {
    local _current_instance="${1:-}"
    print_section "Configure Edge"

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

    local conflict_inst
    conflict_inst=$(check_ip_conflict_with_instances "$EDGE_IP" "$_current_instance")
    if [[ -n "$conflict_inst" ]]; then
        printf "  ${YELLOW}  ↳ Warning: IP %s is already used by instance '%s'${RESET}\n" "$EDGE_IP" "$conflict_inst"
    fi

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

    echo ""
    if ask_yesno "Configure advanced options? (MTU, routing, compression, etc.)" "n"; then
        configure_edge_advanced || return 1
    fi
}

configure_edge_advanced() {
    echo ""
    print_info "── Advanced Edge Options ──"
    echo ""

    while true; do
        ask "MTU (500-1500)" "$EDGE_MTU" EDGE_MTU
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_mtu "$EDGE_MTU" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    if ask_yesno "Enable packet forwarding?" "${EDGE_ROUTING}"; then
        EDGE_ROUTING="y"

        echo ""
        print_info "Add routes to push through the VPN (e.g. 10.0.0.0/8:10.55.0.254)."
        print_info "Leave empty to skip."
        local route_input
        while true; do
            ask "Route (CIDR:gateway or empty)" "${EDGE_ROUTES:-}" route_input
            $_STDIN_EOF && return 1
            if [[ -z "$route_input" ]]; then
                EDGE_ROUTES=""
                break
            fi
            local err
            if err=$(validate_route "$route_input" 2>&1); then
                EDGE_ROUTES="$route_input"
                break
            else
                printf "  ${RED}  ↳ %s${RESET}\n" "$err"
            fi
        done
    else
        EDGE_ROUTING="n"
        EDGE_ROUTES=""
    fi

    if ask_yesno "Accept multicast MAC addresses?" "${EDGE_MULTICAST}"; then
        EDGE_MULTICAST="y"
    else
        EDGE_MULTICAST="n"
    fi

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

    while true; do
        ask "Management port" "$EDGE_MGMT_PORT" EDGE_MGMT_PORT
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_port "$EDGE_MGMT_PORT" "Management port" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    ask "Device description / username" "$EDGE_DESCRIPTION" EDGE_DESCRIPTION

    echo ""
    ask_choice "Verbosity level" EDGE_VERBOSITY \
        "Normal" \
        "Verbose (-v)" \
        "Very verbose (-v -v)" \
        "Debug (-v -v -v)" || return 1
    EDGE_VERBOSITY=$(( EDGE_VERBOSITY - 1 ))
}

# ── Edit Subsections ────────────────────────────────────────────────────────

edit_network_settings() {
    local _current_instance="${1:-}"
    print_section "Edit Network Settings"

    while true; do
        ask "Community name" "$EDGE_COMMUNITY" EDGE_COMMUNITY
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_community "$EDGE_COMMUNITY" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

    echo ""
    while true; do
        ask "Supernode (host:port)" "$EDGE_SUPERNODE" EDGE_SUPERNODE
        $_STDIN_EOF && return 1
        local err
        if err=$(validate_supernode_addr "$EDGE_SUPERNODE" 2>&1); then break
        else printf "  ${RED}  ↳ %s${RESET}\n" "$err"; fi
    done

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

# ── do_edit ─────────────────────────────────────────────────────────────────

do_edit() {
    local instance_name="${1:-}"
    acquire_lock
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

    local port_conflict
    port_conflict=$(check_mgmt_port_conflict "$EDGE_MGMT_PORT" "$instance_name")
    if [[ -n "$port_conflict" ]]; then
        printf "  ${YELLOW}  ↳ Mgmt port %s conflicts with instance '%s'. Auto-assigning.${RESET}\n" "$EDGE_MGMT_PORT" "$port_conflict"
        EDGE_MGMT_PORT=$(next_available_mgmt_port)
        printf "  ${GREEN}  ↳ Using port %s${RESET}\n" "$EDGE_MGMT_PORT"
    fi

    echo ""
    review_edge_config "$instance_name"

    echo ""
    if ! ask_yesno "Save changes?" "y"; then
        print_status "$SYM_WARN" "Changes discarded."
        return
    fi

    local conf_path
    conf_path="$(instance_config_path "$instance_name")"
    local backup_path="${conf_path}.bak"

    cp "$conf_path" "$backup_path"
    generate_edge_conf "$conf_path" "$instance_name"
    chmod 600 "$conf_path"
    print_status "$SYM_OK" "Config updated."

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
