#!/usr/bin/env bash
# cmd/migrate.sh — detect_legacy_instance, do_migrate

[[ -n "${_CMD_MIGRATE_LOADED:-}" ]] && return 0
_CMD_MIGRATE_LOADED=1

detect_legacy_instance() {
    local legacy_conf="$CONFIG_DIR/edge.conf"
    local legacy_plist="${PLIST_DIR}/org.ntop.n2n-edge.plist"

    if [[ -f "$legacy_conf" ]] || [[ -f "$legacy_plist" ]]; then
        return 0
    fi
    return 1
}

do_migrate() {
    acquire_lock
    detect_binaries

    print_header "Migrate Legacy Configuration"

    local legacy_conf="$CONFIG_DIR/edge.conf"
    local legacy_plist="${PLIST_DIR}/org.ntop.n2n-edge.plist"
    local found=false

    if [[ -f "$legacy_conf" ]]; then
        found=true
        print_status "$SYM_DOT" "Found: $legacy_conf"
    fi
    if [[ -f "$legacy_plist" ]]; then
        found=true
        print_status "$SYM_DOT" "Found: $legacy_plist"
    fi

    if ! $found; then
        print_status "$SYM_OK" "No legacy configuration found."
        return
    fi

    echo ""
    print_info "Your old single-instance setup will be migrated to the new"
    print_info "multi-instance format. You'll choose a name for the instance."
    echo ""

    local migrate_name="default"
    ask "Instance name for migrated config" "$migrate_name" migrate_name

    local err
    if ! err=$(validate_instance_name "$migrate_name" 2>&1); then
        print_status "$SYM_FAIL" "$err"
        return
    fi
    if instance_exists "$migrate_name"; then
        print_status "$SYM_FAIL" "Instance '$migrate_name' already exists."
        return
    fi

    if [[ -f "$legacy_conf" ]]; then
        local conf_dir
        conf_dir="$(instance_config_dir "$migrate_name")"
        mkdir -p "$conf_dir"
        chmod 700 "$conf_dir"
        cp "$legacy_conf" "$(instance_config_path "$migrate_name")"
        chmod 600 "$(instance_config_path "$migrate_name")"
        print_status "$SYM_OK" "Migrated config to: $(instance_config_path "$migrate_name")"

        if ask_yesno "Remove old config file?" "y"; then
            rm -f "$legacy_conf"
            print_status "$SYM_OK" "Removed: $legacy_conf"
        fi
    fi

    if [[ -f "$legacy_plist" ]]; then
        if launchd_label_loaded "org.ntop.n2n-edge"; then
            _launchctl_unload "org.ntop.n2n-edge" "$legacy_plist"
            print_status "$SYM_OK" "Unloaded legacy daemon"
        fi

        if [[ -n "$EDGE_BIN" ]] && instance_exists "$migrate_name"; then
            if parse_edge_conf "$(instance_config_path "$migrate_name")"; then
                install_instance_daemon "$migrate_name"
            else
                print_status "$SYM_WARN" "Could not read migrated config. Daemon not installed."
            fi
        elif ! instance_exists "$migrate_name"; then
            print_status "$SYM_WARN" "Legacy plist found but no config file to migrate."
            print_info "The old daemon will be removed. Use '$(basename "$0") create $migrate_name' to set up a new instance."
        fi

        if ask_yesno "Remove old plist file?" "y"; then
            sudo rm -f "$legacy_plist"
            print_status "$SYM_OK" "Removed: $legacy_plist"
        fi
    fi

    echo ""
    print_status "$SYM_OK" "${BOLD}Migration complete. Instance '${migrate_name}' is ready.${RESET}"
    print_info "Start with: $(basename "$0") start $migrate_name"
}
