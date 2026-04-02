#!/usr/bin/env bash
# lib/core.sh — Constants, paths, colors, cleanup trap, lock, sudo helper
# Sourced by wizard.sh entry point. Must be loaded first.

[[ -n "${_LIB_CORE_LOADED:-}" ]] && return 0
_LIB_CORE_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
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
    SCRIPT_DIR="$(_resolve_script_dir)"
fi
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.0.0-dev")

CONFIG_DIR="$HOME/.config/n2n"
INSTANCES_DIR="$CONFIG_DIR/instances"
PLIST_DIR="/Library/LaunchDaemons"
PLIST_PREFIX="org.ntop.n2n-edge"
SN_PLIST_LABEL="org.ntop.n2n-supernode"
LOGROTATE_LABEL="org.ntop.n2n-logrotate"
LOG_DIR="/var/log"
EDGE_BIN="${EDGE_BIN:-}"
SUPERNODE_BIN="${SUPERNODE_BIN:-}"

# ── Colors & Symbols ────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    BOLD='\033[1m'       DIM='\033[2m'        RESET='\033[0m'
    RED='\033[0;31m'     GREEN='\033[0;32m'   YELLOW='\033[0;33m'
    CYAN='\033[0;36m'    WHITE='\033[1;37m'   GRAY='\033[0;90m'
else
    BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW=''
    CYAN='' WHITE='' GRAY=''
fi

SYM_OK="${GREEN}✓${RESET}"
SYM_FAIL="${RED}✗${RESET}"
SYM_WARN="${YELLOW}⚠${RESET}"
SYM_ARROW="${CYAN}▸${RESET}"
SYM_DOT="${GRAY}·${RESET}"
SYM_LOCK="${YELLOW}🔒${RESET}"

# ── Cleanup ─────────────────────────────────────────────────────────────────

_CLEANUP_FILES=()
LOCK_FILE="${CONFIG_DIR}/.mac2n.lock"
_LOCK_HELD=false

_cleanup() {
    if $_LOCK_HELD; then
        rm -f "$LOCK_FILE" 2>/dev/null || true
    fi
    (( ${#_CLEANUP_FILES[@]} > 0 )) || return 0
    local f
    for f in "${_CLEANUP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
trap _cleanup EXIT

# ── Locking ─────────────────────────────────────────────────────────────────

acquire_lock() {
    [[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"
    local max_wait=10 waited=0
    while ! (set -o noclobber; echo $$ > "$LOCK_FILE") 2>/dev/null; do
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$LOCK_FILE"
            continue
        fi
        if (( waited >= max_wait )); then
            print_status "$SYM_FAIL" "Another mac2n instance is running (PID ${lock_pid:-?}). Try again later."
            exit 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    _LOCK_HELD=true
}

release_lock() {
    if $_LOCK_HELD; then
        rm -f "$LOCK_FILE" 2>/dev/null || true
        _LOCK_HELD=false
    fi
}

# ── Sudo ────────────────────────────────────────────────────────────────────

ensure_sudo() {
    if ! sudo -n true 2>/dev/null; then
        sudo -v
    fi
}

_STDIN_EOF=false
