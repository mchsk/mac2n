#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# mac2n — N2N VPN for macOS
# Multi-instance edge management with full CRUD, supernode support,
# and LaunchDaemon integration (native utun interface)
# ─────────────────────────────────────────────────────────────────────────────

# Resolve script directory (follows symlinks)
_resolve_script_dir() {
    local src="$0"
    while [[ -L "$src" ]]; do
        local dir
        dir="$(cd "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd "$(dirname "$src")" && pwd
}
_ENTRY_DIR="$(_resolve_script_dir)"

# ── Source Libraries (dependency order) ─────────────────────────────────────

source "$_ENTRY_DIR/lib/core.sh"
source "$_ENTRY_DIR/lib/ui.sh"
source "$_ENTRY_DIR/lib/validate.sh"
source "$_ENTRY_DIR/lib/instance.sh"
source "$_ENTRY_DIR/lib/service.sh"
source "$_ENTRY_DIR/lib/edge_model.sh"
source "$_ENTRY_DIR/lib/supernode_model.sh"
source "$_ENTRY_DIR/lib/presets.sh"

# ── Source Commands ─────────────────────────────────────────────────────────

source "$_ENTRY_DIR/cmd/create.sh"
source "$_ENTRY_DIR/cmd/edit.sh"
source "$_ENTRY_DIR/cmd/show.sh"
source "$_ENTRY_DIR/cmd/delete.sh"
source "$_ENTRY_DIR/cmd/service_ctl.sh"
source "$_ENTRY_DIR/cmd/supernode_cmd.sh"
source "$_ENTRY_DIR/cmd/status.sh"
source "$_ENTRY_DIR/cmd/migrate.sh"
source "$_ENTRY_DIR/cmd/update.sh"
source "$_ENTRY_DIR/cmd/uninstall.sh"
source "$_ENTRY_DIR/cmd/menu.sh"

# ── Main ────────────────────────────────────────────────────────────────────

main() {
    _preflight_health_check
    case "${1:-menu}" in
        menu|wizard|configure|setup)
            do_interactive_menu
            ;;
        create|new|add)
            do_create "${2:-}"
            ;;
        list|ls)
            do_list
            ;;
        show|info|inspect)
            do_show "${2:-}"
            ;;
        edit|modify)
            do_edit "${2:-}"
            ;;
        delete|remove|rm)
            do_delete "${2:-}"
            ;;
        start)
            do_start "${2:-}"
            ;;
        stop)
            do_stop "${2:-}"
            ;;
        restart)
            do_restart "${2:-}"
            ;;
        logs|log|tail)
            do_logs "${2:-}"
            ;;
        status)
            do_status
            ;;
        supernode|sn)
            do_supernode "${2:-}"
            ;;
        self-update|upgrade)
            do_update
            ;;
        migrate)
            do_migrate
            ;;
        uninstall)
            do_uninstall
            ;;
        help|-h|--help)
            do_help
            ;;
        --version|-V)
            echo "mac2n v${VERSION}"
            ;;
        *)
            printf "${RED}Unknown command: %s${RESET}\n" "$1" >&2
            do_help
            exit 1
            ;;
    esac
}

main "$@"
