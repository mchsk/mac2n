#!/usr/bin/env bash
# cmd/uninstall.sh — Unified uninstall: single source of truth
# Both wizard.sh and install.sh source this for teardown logic.

[[ -n "${_CMD_UNINSTALL_LOADED:-}" ]] && return 0
_CMD_UNINSTALL_LOADED=1

# Non-interactive service teardown (used by test-e2e.sh, install.sh --uninstall)
uninstall_services() {
    detect_binaries

    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    local name
    for name in ${names[@]+"${names[@]}"}; do
        local label
        label="$(instance_plist_label "$name")"
        if instance_is_loaded "$name"; then
            _launchctl_stop "$label"
            _launchctl_unload "$label" "$(instance_plist_path "$name")"
        elif instance_is_running "$name"; then
            local pid
            pid=$(instance_pid "$name")
            [[ -n "$pid" ]] && sudo kill "$pid" 2>/dev/null || true
        fi
        if instance_plist_installed "$name"; then
            sudo rm -f "$(instance_plist_path "$name")"
        fi
    done

    if launchd_label_loaded "$SN_PLIST_LABEL"; then
        _launchctl_stop "$SN_PLIST_LABEL"
        _launchctl_unload "$SN_PLIST_LABEL" "${PLIST_DIR}/${SN_PLIST_LABEL}.plist"
    fi
    sudo rm -f "${PLIST_DIR}/${SN_PLIST_LABEL}.plist" 2>/dev/null || true

    if [[ -f "${PLIST_DIR}/org.ntop.n2n-edge.plist" ]]; then
        _launchctl_unload "org.ntop.n2n-edge" "${PLIST_DIR}/org.ntop.n2n-edge.plist"
        sudo rm -f "${PLIST_DIR}/org.ntop.n2n-edge.plist"
    fi

    remove_logrotation

    local fw="/usr/libexec/ApplicationFirewall/socketfilterfw"
    if [[ -x "$fw" ]]; then
        local -a fw_bins=(/opt/mac2n/sbin/edge /opt/mac2n/sbin/supernode
                          /usr/local/sbin/edge /usr/local/sbin/supernode)
        [[ -n "$EDGE_BIN" ]] && fw_bins+=("$EDGE_BIN")
        [[ -n "$SUPERNODE_BIN" ]] && fw_bins+=("$SUPERNODE_BIN")
        local seen="" bin
        for bin in "${fw_bins[@]}"; do
            [[ "$seen" == *"|${bin}|"* ]] && continue
            seen="${seen}|${bin}|"
            [[ -f "$bin" ]] && sudo "$fw" --remove "$bin" 2>/dev/null || true
        done
    fi
}

# Interactive uninstall (used by wizard.sh)
do_uninstall() {
    acquire_lock
    detect_binaries

    print_header "Uninstall mac2n"

    local found=false

    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} > 0 )); then
        found=true
        print_status "$SYM_DOT" "${#names[@]} edge instance(s): ${names[*]}"
    fi

    if [[ -f "$CONFIG_DIR/supernode.conf" ]]; then
        found=true
        print_status "$SYM_DOT" "Supernode configuration"
    fi
    if [[ -f "${PLIST_DIR}/${SN_PLIST_LABEL}.plist" ]]; then
        found=true
        print_status "$SYM_DOT" "Supernode LaunchDaemon"
    fi

    if [[ -f "$CONFIG_DIR/edge.conf" ]]; then
        found=true
        print_status "$SYM_DOT" "Legacy edge config"
    fi
    if [[ -f "${PLIST_DIR}/org.ntop.n2n-edge.plist" ]]; then
        found=true
        print_status "$SYM_DOT" "Legacy edge LaunchDaemon"
    fi

    if ! $found; then
        print_status "$SYM_OK" "Nothing to uninstall."
        return
    fi

    echo ""
    printf "  ${RED}${BOLD}This will remove ALL n2n services and configuration.${RESET}\n"
    if ! ask_yesno "Are you sure?" "n"; then
        print_status "$SYM_DOT" "Aborted."
        return
    fi

    uninstall_services

    for name in ${names[@]+"${names[@]}"}; do
        print_status "$SYM_OK" "Removed edge instance: $name"
    done
    print_status "$SYM_OK" "Removed supernode daemon"
    print_status "$SYM_OK" "Removed log rotation daemon"
    print_status "$SYM_OK" "Removed firewall exceptions"

    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        print_status "$SYM_OK" "Removed config directory: $CONFIG_DIR"
    fi

    if ask_yesno "Remove all n2n log files?" "y"; then
        sudo rm -f /var/log/n2n-edge*.log /var/log/n2n-supernode.log /var/log/n2n-*.log.*.gz 2>/dev/null || true
        print_status "$SYM_OK" "Removed log files"
    fi

    echo ""
    print_info "Note: n2n binaries were not removed. To remove them:"
    print_info "  sudo rm -f /opt/mac2n/sbin/edge /opt/mac2n/sbin/supernode"
    print_info "Or run: ~/.mac2n/install.sh --uninstall"
    echo ""
    print_status "$SYM_OK" "${BOLD}Uninstall complete.${RESET}"
}
