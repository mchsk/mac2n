#!/usr/bin/env bash
# lib/instance.sh — Instance path helpers, discovery, status queries, binary detection
# Depends on: lib/core.sh

[[ -n "${_LIB_INSTANCE_LOADED:-}" ]] && return 0
[[ -n "${_LIB_CORE_LOADED:-}" ]] || { echo "lib/instance.sh: lib/core.sh must be loaded first" >&2; exit 1; }
_LIB_INSTANCE_LOADED=1

# ── Path Helpers ─────────────────────────────────────────────────────────────

instance_config_dir() { echo "$INSTANCES_DIR/$1"; }
instance_config_path() { echo "$INSTANCES_DIR/$1/edge.conf"; }
instance_plist_label() { echo "${PLIST_PREFIX}.$1"; }
instance_plist_path() { echo "${PLIST_DIR}/${PLIST_PREFIX}.$1.plist"; }
instance_log_path() { echo "${LOG_DIR}/n2n-edge-$1.log"; }

# ── Instance Discovery ──────────────────────────────────────────────────────

list_instance_names() {
    if [[ ! -d "$INSTANCES_DIR" ]]; then
        return
    fi
    local dir
    for dir in "$INSTANCES_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name="$(basename "$dir")"
        if [[ -f "$dir/edge.conf" ]]; then
            printf '%s\n' "$name"
        fi
    done
}

instance_exists() {
    [[ -f "$(instance_config_path "$1")" ]]
}

instance_plist_installed() {
    [[ -f "$(instance_plist_path "$1")" ]]
}

instance_status_plain() {
    if instance_is_running "$1"; then echo "running"
    elif instance_is_loaded "$1"; then echo "loaded"
    elif instance_plist_installed "$1"; then echo "installed"
    else echo "config-only"
    fi
}

# ── Binary Detection ────────────────────────────────────────────────────────

detect_binaries() {
    if [[ -z "$EDGE_BIN" ]]; then
        EDGE_BIN=$(command -v edge 2>/dev/null || echo "")
    fi
    if [[ -z "$EDGE_BIN" ]] && [[ -x /opt/mac2n/sbin/edge ]]; then
        EDGE_BIN="/opt/mac2n/sbin/edge"
    fi
    if [[ -z "$EDGE_BIN" ]] && [[ -x /usr/local/sbin/edge ]]; then
        EDGE_BIN="/usr/local/sbin/edge"
    fi
    if [[ -z "$EDGE_BIN" ]] && [[ -x /usr/local/bin/edge ]]; then
        EDGE_BIN="/usr/local/bin/edge"
    fi
    if [[ -z "$SUPERNODE_BIN" ]]; then
        SUPERNODE_BIN=$(command -v supernode 2>/dev/null || echo "")
    fi
    if [[ -z "$SUPERNODE_BIN" ]] && [[ -x /opt/mac2n/sbin/supernode ]]; then
        SUPERNODE_BIN="/opt/mac2n/sbin/supernode"
    fi
    if [[ -z "$SUPERNODE_BIN" ]] && [[ -x /usr/local/sbin/supernode ]]; then
        SUPERNODE_BIN="/usr/local/sbin/supernode"
    fi
    if [[ -z "$SUPERNODE_BIN" ]] && [[ -x /usr/local/bin/supernode ]]; then
        SUPERNODE_BIN="/usr/local/bin/supernode"
    fi
}

require_edge_binary() {
    if [[ -z "$EDGE_BIN" ]]; then
        print_status "$SYM_FAIL" "edge binary not found. Run: cd ~/.mac2n && ./build.sh all"
        return 1
    fi
}
