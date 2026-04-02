#!/usr/bin/env bash
# cmd/create.sh — do_create: interactive wizard to create a new edge instance

[[ -n "${_CMD_CREATE_LOADED:-}" ]] && return 0
_CMD_CREATE_LOADED=1

do_create() {
    local instance_name="${1:-}"
    acquire_lock

    detect_binaries
    require_edge_binary || return 1

    print_header "Create Edge Instance"

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

    reset_edge_defaults
    EDGE_DESCRIPTION="$(hostname -s)-${instance_name}"

    select_usecase || return 1
    apply_usecase_defaults
    EDGE_MGMT_PORT=$(next_available_mgmt_port)

    configure_edge "$instance_name" || return 1

    local port_conflict
    port_conflict=$(check_mgmt_port_conflict "$EDGE_MGMT_PORT" "$instance_name")
    if [[ -n "$port_conflict" ]]; then
        printf "  ${YELLOW}  ↳ Mgmt port %s conflicts with instance '%s'. Auto-assigning.${RESET}\n" "$EDGE_MGMT_PORT" "$port_conflict"
        EDGE_MGMT_PORT=$(next_available_mgmt_port)
        printf "  ${GREEN}  ↳ Using port %s${RESET}\n" "$EDGE_MGMT_PORT"
    fi

    review_edge_config "$instance_name"

    echo ""
    if ! ask_yesno "Save this configuration?" "y"; then
        print_status "$SYM_WARN" "Aborted."
        return
    fi

    local conf_dir
    conf_dir="$(instance_config_dir "$instance_name")"
    mkdir -p "$conf_dir"
    chmod 700 "$conf_dir"
    generate_edge_conf "$(instance_config_path "$instance_name")" "$instance_name"
    chmod 600 "$(instance_config_path "$instance_name")"
    print_status "$SYM_OK" "Config saved: $(instance_config_path "$instance_name")"

    echo ""
    if ask_yesno "Install as LaunchDaemon (auto-start at boot)?" "y"; then
        install_instance_daemon "$instance_name"
    fi

    if instance_plist_installed "$instance_name"; then
        echo ""
        if ask_yesno "Start this instance now?" "y"; then
            do_start "$instance_name"
        fi
    fi

    echo ""
    print_status "$SYM_OK" "${BOLD}Instance '${instance_name}' created successfully.${RESET}"
}
