#!/usr/bin/env bash
# cmd/update.sh — do_update (self-update)

[[ -n "${_CMD_UPDATE_LOADED:-}" ]] && return 0
_CMD_UPDATE_LOADED=1

do_update() {
    acquire_lock
    detect_binaries

    if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
        print_status "$SYM_FAIL" "Not a git checkout — cannot self-update."
        print_info "Re-install with: bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/mchsk/mac2n/main/install.sh)\""
        return 1
    fi

    print_header "Update mac2n"

    cd "$SCRIPT_DIR" || return 1

    local current_version="$VERSION"
    print_info "Current version: v${current_version}"

    if ! git fetch --quiet origin 2>/dev/null; then
        print_status "$SYM_FAIL" "Could not reach remote — check your internet connection."
        return 1
    fi

    local behind
    behind=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
    if (( behind == 0 )); then
        print_status "$SYM_OK" "Already up to date."
        return
    fi

    print_info "$behind new commit(s) available."
    echo ""

    if ! ask_yesno "Pull updates and rebuild?" "y"; then
        print_status "$SYM_DOT" "Aborted."
        return
    fi

    if ! git pull --ff-only --quiet 2>&1; then
        print_status "$SYM_FAIL" "git pull failed — you may have local changes. Try: git stash && mac2n self-update"
        return 1
    fi

    if ! git submodule update --init --quiet 2>&1; then
        print_status "$SYM_FAIL" "Submodule update failed."
        return 1
    fi

    print_status "$SYM_OK" "Source updated."

    echo ""
    if ask_yesno "Rebuild n2n from updated source?" "y"; then
        ensure_sudo

        local running_instances=()
        while IFS= read -r _name; do
            [[ -n "$_name" ]] && instance_is_running "$_name" && running_instances+=("$_name")
        done < <(list_instance_names)

        local sn_was_running=false
        if launchd_label_loaded "$SN_PLIST_LABEL"; then
            sn_was_running=true
        fi

        if (( ${#running_instances[@]} > 0 )) || $sn_was_running; then
            print_status "$SYM_ARROW" "Stopping running instances for safe upgrade..."
            for _name in "${running_instances[@]}"; do
                do_stop "$_name"
            done
            $sn_was_running && do_supernode_stop
        fi

        if ! bash ./build.sh all 2>&1; then
            print_status "$SYM_FAIL" "Build failed — check output above."
            for _name in "${running_instances[@]}"; do
                do_start "$_name" 2>/dev/null || true
            done
            $sn_was_running && do_supernode_start 2>/dev/null || true
            return 1
        fi

        if (( ${#running_instances[@]} > 0 )) || $sn_was_running; then
            print_status "$SYM_ARROW" "Restarting instances..."
            $sn_was_running && do_supernode_start
            for _name in "${running_instances[@]}"; do
                do_start "$_name"
            done
        fi
    fi

    local new_version
    new_version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
    echo ""
    print_status "$SYM_OK" "${BOLD}Updated to v${new_version}.${RESET}"
}
