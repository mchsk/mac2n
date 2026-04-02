#!/usr/bin/env bash
# cmd/menu.sh — do_interactive_menu, do_help

[[ -n "${_CMD_MENU_LOADED:-}" ]] && return 0
_CMD_MENU_LOADED=1

do_interactive_menu() {
    detect_binaries

    if detect_legacy_instance 2>/dev/null; then
        echo ""
        printf "  ${YELLOW}${BOLD}Legacy single-instance setup detected.${RESET}\n"
        if ask_yesno "Migrate to multi-instance format now?" "y"; then
            do_migrate
            echo ""
        fi
    fi

    while true; do
        print_header "mac2n" "N2N VPN for macOS · native utun interface"

        local names=()
        while IFS= read -r name; do
            [[ -n "$name" ]] && names+=("$name")
        done < <(list_instance_names)

        if (( ${#names[@]} > 0 )); then
            local running=0
            local name
            for name in "${names[@]}"; do
                if instance_is_running "$name"; then running=$((running + 1)); fi
            done
            printf "  ${DIM}%d instance(s), %d running${RESET}\n\n" "${#names[@]}" "$running"
        fi

        printf "    ${WHITE}1)${RESET} Create new edge instance\n"
        printf "    ${WHITE}2)${RESET} List all instances\n"
        printf "    ${WHITE}3)${RESET} Show instance details\n"
        printf "    ${WHITE}4)${RESET} Edit instance\n"
        printf "    ${WHITE}5)${RESET} Delete instance\n"
        printf "    ${WHITE}6)${RESET} Start / Stop / Restart\n"
        printf "    ${WHITE}7)${RESET} View logs\n"
        printf "    ${WHITE}8)${RESET} Supernode management\n"
        printf "    ${WHITE}9)${RESET} Full status overview\n"
        printf "    ${WHITE}0)${RESET} Exit\n"
        echo ""

        local choice
        printf "  ${SYM_ARROW} ${BOLD}Select action${RESET} ${DIM}[0-9]${RESET}: "
        if ! read -r choice; then
            echo ""
            print_status "$SYM_OK" "Goodbye."
            echo ""
            exit 0
        fi

        case "$choice" in
            1) do_create || true ;;
            2) do_list || true ;;
            3) do_show || true ;;
            4) do_edit || true ;;
            5) do_delete || true ;;
            6)
                echo ""
                local svc_action
                ask_choice "Service action" svc_action \
                    "Start instance" \
                    "Stop instance" \
                    "Restart instance" \
                    "Start all" \
                    "Stop all" \
                    "Restart all" \
                    "Back"
                case $svc_action in
                    1) do_start || true ;;
                    2) do_stop || true ;;
                    3) do_restart || true ;;
                    4) do_start "--all" || true ;;
                    5) do_stop "--all" || true ;;
                    6) do_restart "--all" || true ;;
                    7) ;;
                esac
                ;;
            7) do_logs || true ;;
            8) do_supernode || true ;;
            9) do_status || true ;;
            0|q|Q|exit)
                echo ""
                print_status "$SYM_OK" "Goodbye."
                echo ""
                exit 0
                ;;
            *)
                printf "  ${RED}Invalid choice.${RESET}\n"
                sleep 1
                ;;
        esac

        echo ""
        printf "  ${DIM}Press Enter to return to menu...${RESET}"
        read -r || true
    done
}

do_help() {
    cat <<EOF

  $(printf "${BOLD}mac2n — N2N VPN for macOS${RESET}") $(printf "${DIM}v${VERSION}${RESET}")

  $(printf "${WHITE}Usage:${RESET}")  $(basename "$0") <command> [args]

  $(printf "${WHITE}Instance Management:${RESET}")
    create [name]       Create a new edge instance (interactive wizard)
    list                List all configured instances with status
    show <name>         Show detailed info for an instance
    edit <name>         Edit an existing instance configuration
    delete <name>       Delete an instance (stops if running)

  $(printf "${WHITE}Service Control:${RESET}")
    start <name|--all>  Start instance(s)
    stop <name|--all>   Stop instance(s)
    restart <name|--all> Restart instance(s)
    logs <name>         Tail logs for an instance

  $(printf "${WHITE}Supernode:${RESET}")
    supernode [create|status|start|stop|restart|delete]

  $(printf "${WHITE}Other:${RESET}")
    status              Show full status overview
    self-update         Pull latest source and rebuild
    migrate             Migrate legacy single-instance setup
    uninstall           Remove all n2n services and configuration
    help                Show this help
    --version, -V       Print version and exit

  $(printf "${WHITE}Examples:${RESET}")
    $(basename "$0")                  Interactive menu
    $(basename "$0") create home      Create instance named "home"
    $(basename "$0") list             Show all instances
    $(basename "$0") start home       Start the "home" instance
    $(basename "$0") start --all      Start all instances
    $(basename "$0") edit home        Edit the "home" instance
    $(basename "$0") status           Full system status

EOF
}
