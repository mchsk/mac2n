#!/usr/bin/env bash
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0" 2>/dev/null)" 2>/dev/null && pwd 2>/dev/null || echo "")"
VERSION=$(cat "${_SCRIPT_DIR}/VERSION" 2>/dev/null || echo "1.0.0")
REPO_URL="https://github.com/mchsk/mac2n.git"
INSTALL_DIR="$HOME/.mac2n"
LINK_PATH="/opt/mac2n/bin/mac2n"
TOTAL_STEPS=6

# ── Cleanup ───────────────────────────────────────────────────────────────────

_CLEANUP_FILES=()
_CLEANUP_PIDS=()
_run_cleanup() {
    local f
    for f in ${_CLEANUP_FILES[@]+"${_CLEANUP_FILES[@]}"}; do
        sudo rm -f "$f" 2>/dev/null || true
    done
    local p
    for p in ${_CLEANUP_PIDS[@]+"${_CLEANUP_PIDS[@]}"}; do
        kill "$p" 2>/dev/null || true
    done
}
trap _run_cleanup EXIT

# ── Display ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    BOLD='\033[1m'  DIM='\033[2m'  RESET='\033[0m'
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
    CYAN='\033[0;36m' WHITE='\033[1;37m' GRAY='\033[0;90m'
else
    BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW='' CYAN='' WHITE='' GRAY=''
fi

step_ok()   { printf "  ${GREEN}✓${RESET} [%d/%d] %s\n" "$1" "$TOTAL_STEPS" "$2"; }
step_run()  { printf "  ${DIM}…${RESET} [%d/%d] %s\n" "$1" "$TOTAL_STEPS" "$2"; }
step_fail() { printf "  ${RED}✗${RESET} [%d/%d] %s\n" "$1" "$TOTAL_STEPS" "$2"; }
die()       { step_fail "$1" "$2"; exit 1; }

# ── Uninstall ────────────────────────────────────────────────────────────────

prompt_yn() {
    local prompt=$1 default=${2:-Y} answer
    printf "%s " "$prompt"
    if [[ -t 0 ]]; then
        read -r answer
    elif [[ -e /dev/tty ]]; then
        read -r answer </dev/tty
    else
        answer=""
    fi
    [[ "${answer:-$default}" =~ ^[Yy] ]]
}

do_uninstall() {
    echo ""
    printf "  ${BOLD}mac2n uninstaller${RESET} ${DIM}v${VERSION}${RESET}\n"
    echo ""

    printf "  ${DIM}sudo access required for uninstallation${RESET}\n"
    sudo -v

    # Stop and remove VPN services/configs directly (no delegation to wizard.sh
    # which would show its own header and re-prompt for confirmation)
    local wizard="$INSTALL_DIR/wizard.sh"
    if [[ -x "$wizard" ]]; then
        local has_services=false
        local config_dir="$HOME/.config/n2n"
        [[ -d "$config_dir" ]] && has_services=true
        ls /Library/LaunchDaemons/org.ntop.n2n-* &>/dev/null && has_services=true

        if $has_services; then
            if prompt_yn "  Remove all VPN services and configs? [Y/n]"; then
                # Stop all daemons
                for plist in /Library/LaunchDaemons/org.ntop.n2n-*.plist; do
                    [[ -f "$plist" ]] || continue
                    local _label
                    _label=$(basename "$plist" .plist)
                    sudo launchctl bootout "system/$_label" 2>/dev/null || \
                        sudo launchctl unload "$plist" 2>/dev/null || true
                    sudo rm -f "$plist"
                done
                # Remove config
                [[ -d "$config_dir" ]] && rm -rf "$config_dir"
                # Remove logs (including rotated archives)
                sudo rm -f /var/log/n2n-edge*.log /var/log/n2n-supernode.log /var/log/n2n-*.log.*.gz 2>/dev/null || true
                printf "  ${GREEN}✓${RESET} Removed VPN services, configs, and logs\n"
            fi
        fi
    fi

    local found_bins=false
    for bin in /opt/mac2n/sbin/edge /opt/mac2n/sbin/supernode \
               /usr/local/sbin/edge /usr/local/sbin/supernode; do
        [[ -f "$bin" ]] && found_bins=true && break
    done
    if $found_bins; then
        if prompt_yn "  Remove n2n binaries? [Y/n]"; then
            local fw="/usr/libexec/ApplicationFirewall/socketfilterfw"
            for bin in /opt/mac2n/sbin/edge /opt/mac2n/sbin/supernode \
                       /usr/local/sbin/edge /usr/local/sbin/supernode; do
                [[ -f "$bin" ]] || continue
                [[ -x "$fw" ]] && sudo "$fw" --remove "$bin" 2>/dev/null || true
                sudo rm -f "$bin"
            done
            sudo rm -rf /opt/mac2n/lib /usr/local/lib/n2n 2>/dev/null || true
            printf "  ${GREEN}✓${RESET} Removed binaries, libs, and firewall exceptions\n"
        fi
    fi

    local remove_dir=false
    if [[ -d "$INSTALL_DIR" ]]; then
        if prompt_yn "  Remove $INSTALL_DIR? [Y/n]"; then
            rm -rf "$INSTALL_DIR"
            printf "  ${GREEN}✓${RESET} Removed $INSTALL_DIR\n"
            remove_dir=true
        fi
    fi

    # Remove symlinks from both old and new locations
    for link in /opt/mac2n/bin/mac2n /usr/local/bin/mac2n; do
        if [[ -L "$link" ]] || [[ -f "$link" ]]; then
            if $remove_dir; then
                sudo rm -f "$link"
                printf "  ${GREEN}✓${RESET} Removed $link\n"
            else
                printf "  ${DIM}…${RESET} Kept $link (install dir was kept)\n"
            fi
        fi
    done

    # Remove PATH entry from shell profiles
    for rcfile in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        [[ -f "$rcfile" ]] || continue
        if grep -q '/opt/mac2n/bin' "$rcfile" 2>/dev/null; then
            sed -i '' '\|/opt/mac2n/bin|d' "$rcfile"
        fi
    done

    # Clean up /opt/mac2n if empty
    if [[ -d /opt/mac2n ]]; then
        sudo rm -rf /opt/mac2n/bin /opt/mac2n/share 2>/dev/null || true
        rmdir /opt/mac2n 2>/dev/null || true
    fi

    echo ""
    printf "  ${GREEN}✓${RESET} ${BOLD}mac2n uninstalled.${RESET}\n"
    echo ""
    exit 0
}

# ── Step 1: Xcode Command Line Tools ─────────────────────────────────────────

is_ssh() { [[ -n "${SSH_CONNECTION:-}" ]] || [[ -n "${SSH_TTY:-}" ]]; }

CLT_DEFERRED=false

_parse_clt_label() {
    local output="$1"
    # Primary: Homebrew's proven pattern — handles "* Label: ..." and "* ..." formats
    local label
    label=$(echo "$output" \
        | grep -B 1 -E 'Command Line Tools' \
        | awk -F'*' '/^\*/{print $2}' \
        | sed -e 's/^ *Label: //' -e 's/^ *//' \
        | sort -V \
        | tail -n1 \
        | xargs) || true

    # Fallback: broader pattern for unexpected format changes
    if [[ -z "$label" ]]; then
        label=$(echo "$output" \
            | grep -io 'Command Line Tools[^"]*' \
            | sort -V \
            | tail -n1 \
            | xargs) || true
    fi

    echo "$label"
}

_verify_clt_binaries() {
    local n=$1
    xcode-select -p &>/dev/null || return 1
    command -v git &>/dev/null  || die $n "git not found after CLT install"
    # Verify clang is functional (safe after xcode-select -p succeeds — won't trigger GUI)
    clang --version &>/dev/null || \
        die $n "Developer tools present but clang not functional — installation may be corrupt"
    return 0
}

ensure_xcode() {
    local n=1
    if _verify_clt_binaries $n 2>/dev/null; then
        step_ok $n "Xcode Command Line Tools"
        return
    fi

    step_run $n "Installing Xcode Command Line Tools"
    printf "        ${DIM}sudo access required${RESET}\n"
    sudo -v

    # Trigger softwareupdate to list CLT as an available package
    local marker="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    sudo touch "$marker"
    _CLEANUP_FILES+=("$marker")

    printf "        ${DIM}Searching for package (this can take a minute)...${RESET}\n"
    local su_output="" label="" attempts=0 max_attempts=3
    while [[ -z "$label" ]] && (( attempts < max_attempts )); do
        (( attempts > 0 )) && {
            printf "        ${DIM}Retrying (%d/%d)...${RESET}\n" "$((attempts + 1))" "$max_attempts"
            sleep 10
        }
        su_output=$(softwareupdate --list 2>&1) || true
        label=$(_parse_clt_label "$su_output")
        (( ++attempts ))
    done

    if [[ -n "$label" ]]; then
        printf "        ${DIM}package: %s${RESET}\n" "$label"
        if ! sudo softwareupdate --install "$label" 2>&1 | sed "s/^/        /"; then
            die $n "softwareupdate --install failed (run manually: sudo softwareupdate --install \"$label\")"
        fi
        sudo rm -f "$marker"
        sudo xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
        sudo xcodebuild -license accept 2>/dev/null || true
    else
        sudo rm -f "$marker"

        if is_ssh; then
            printf "        ${YELLOW}Could not find CLT package via softwareupdate after %d attempts${RESET}\n" "$max_attempts"
            if ! curl -fsS --head --max-time 5 https://swscan.apple.com &>/dev/null; then
                printf "        ${RED}Cannot reach Apple update servers (swscan.apple.com)${RESET}\n"
            fi
            if [[ -n "$su_output" ]]; then
                printf "        ${DIM}softwareupdate output:${RESET}\n"
                echo "$su_output" | sed "s/^/            /" | head -20
            fi
            printf "        ${DIM}Deferring to Homebrew (which also installs CLT)...${RESET}\n"
            CLT_DEFERRED=true
            sudo rm -f "$marker" 2>/dev/null || true
            _CLEANUP_FILES=("${_CLEANUP_FILES[@]/$marker/}")
            return
        fi

        # GUI fallback — only works when a display is present
        if xcode-select --install 2>/dev/null; then
            printf "        ${DIM}Waiting for Xcode installer dialog (timeout: 30 min)${RESET}\n"
            local t=0
            until xcode-select -p &>/dev/null; do
                (( t >= 1800 )) && die $n "Timed out waiting for Xcode CLI tools"
                sleep 10; t=$((t + 10))
            done
            sudo xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
            sudo xcodebuild -license accept 2>/dev/null || true
        fi
    fi

    sudo rm -f "$marker" 2>/dev/null || true
    _CLEANUP_FILES=("${_CLEANUP_FILES[@]/$marker/}")

    _verify_clt_binaries $n || die $n "Xcode CLI tools install failed"
    step_ok $n "Xcode Command Line Tools"
}

# ── Step 1b: Post-Homebrew CLT verification (only when deferred) ─────────────

verify_clt() {
    $CLT_DEFERRED || return 0
    local n=1

    if _verify_clt_binaries $n 2>/dev/null; then
        sudo xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
        sudo xcodebuild -license accept 2>/dev/null || true
        step_ok $n "Xcode Command Line Tools (installed via Homebrew)"
        return
    fi

    echo ""
    printf "        ${RED}Xcode Command Line Tools could not be installed automatically${RESET}\n"
    echo ""
    printf "        ${YELLOW}Install manually over SSH:${RESET}\n"
    printf "          ${DIM}sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress${RESET}\n"
    printf "          ${DIM}softwareupdate --list${RESET}\n"
    printf "          ${DIM}sudo softwareupdate --install \"<label from above>\"${RESET}\n"
    printf "          ${DIM}sudo xcode-select --switch /Library/Developer/CommandLineTools${RESET}\n"
    echo ""
    printf "        Then re-run this installer.\n"
    die $n "Xcode CLI tools not available for headless install"
}

# ── Step 2: Homebrew ──────────────────────────────────────────────────────────

ensure_homebrew() {
    local n=2

    # Probe known locations (covers Apple Silicon SSH sessions where PATH is incomplete)
    if ! command -v brew &>/dev/null; then
        for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [[ -x "$p" ]]; then
                eval "$("$p" shellenv)"
                break
            fi
        done
    fi

    if command -v brew &>/dev/null; then
        step_ok $n "Homebrew"
        return
    fi

    step_run $n "Installing Homebrew"
    if $CLT_DEFERRED; then
        printf "        ${DIM}Homebrew will also attempt to install CLT${RESET}\n"
        printf "        ${DIM}If prompted 'Press any key', press Enter to continue${RESET}\n"
    fi
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        2>&1 | sed "s/^/        /" || true

    # Re-probe after install
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$p" ]]; then
            eval "$("$p" shellenv)"
            break
        fi
    done
    command -v brew &>/dev/null || die $n "Homebrew install failed"

    if is_ssh; then
        local rcfile=".zshrc"
        [[ "$(basename "${SHELL:-/bin/zsh}")" == "bash" ]] && rcfile=".bash_profile"
        printf "        ${DIM}Note: add to ~/%s for future sessions:${RESET}\n" "$rcfile"
        printf "        ${DIM}eval \"\$($(command -v brew) shellenv)\"${RESET}\n"
    fi

    step_ok $n "Homebrew"
}

# ── Step 3: Clone / update repo ──────────────────────────────────────────────

fetch_repo() {
    local n=3
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        step_run $n "Updating mac2n"
        cd "$INSTALL_DIR"
        git pull --ff-only --quiet 2>&1 | sed "s/^/        /" || true
        if ! git submodule update --init --quiet 2>&1 | sed "s/^/        /"; then
            die $n "Submodule update failed"
        fi
    else
        [[ -d "$INSTALL_DIR" ]] && mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
        step_run $n "Cloning mac2n"
        if ! git clone --recursive --quiet "$REPO_URL" "$INSTALL_DIR" 2>&1 | sed "s/^/        /"; then
            die $n "Clone failed — check your internet connection"
        fi
        cd "$INSTALL_DIR"
    fi
    step_ok $n "mac2n source"
}

# ── Step 4: Build & install ───────────────────────────────────────────────────

build_and_install() {
    local n=4
    step_run $n "Building n2n (this takes a minute or two)"

    printf "        ${DIM}sudo access required for installation${RESET}\n"
    sudo -v

    # Keep sudo alive in the background (builds can exceed the 5-min timeout)
    while sudo -n true 2>/dev/null; do sleep 50; done &
    local sudo_keepalive_pid=$!
    _CLEANUP_PIDS+=("$sudo_keepalive_pid")

    cd "$INSTALL_DIR"
    if ! bash ./build.sh deps 2>&1 | sed "s/^/        /"; then
        die $n "Installing build dependencies failed"
    fi
    if ! bash ./build.sh source 2>&1 | sed "s/^/        /"; then
        die $n "Fetching n2n source failed"
    fi
    if ! bash ./build.sh build 2>&1 | sed "s/^/        /"; then
        die $n "Build failed — check compiler output above"
    fi
    if ! bash ./build.sh install 2>&1 | sed "s/^/        /"; then
        die $n "Install failed — check output above"
    fi

    kill $sudo_keepalive_pid 2>/dev/null || true
    step_ok $n "n2n built and installed"
}

# ── Step 5: Sign & verify ───────────────────────────────────────────────────

harden_and_verify() {
    local n=5
    step_run $n "Signing binaries and verifying"
    cd "$INSTALL_DIR"
    if ! bash ./build.sh harden 2>&1 | sed "s/^/        /"; then
        die $n "Binary signing failed"
    fi
    if ! bash ./build.sh verify 2>&1 | sed "s/^/        /"; then
        die $n "Binary verification failed — check: otool -L /opt/mac2n/sbin/edge"
    fi
    step_ok $n "Binaries signed and verified"
}

# ── Step 6: Link ─────────────────────────────────────────────────────────────

link() {
    local n=6
    local target="$INSTALL_DIR/wizard.sh"
    [[ -x "$target" ]] || chmod +x "$target"

    local link_dir
    link_dir="$(dirname "$LINK_PATH")"
    [[ -d "$link_dir" ]] || sudo mkdir -p "$link_dir"
    sudo ln -sf "$target" "$LINK_PATH"

    # Remove legacy symlink if present
    [[ -L /usr/local/bin/mac2n ]] && sudo rm -f /usr/local/bin/mac2n

    # Add /opt/mac2n/bin to PATH in shell profile if not already present
    local rcfile="$HOME/.zshrc"
    [[ "$(basename "${SHELL:-/bin/zsh}")" == "bash" ]] && rcfile="$HOME/.bash_profile"
    if ! grep -q '/opt/mac2n/bin' "$rcfile" 2>/dev/null; then
        echo 'export PATH="/opt/mac2n/bin:$PATH"' >> "$rcfile"
        printf "        ${DIM}Added /opt/mac2n/bin to PATH in %s${RESET}\n" "$(basename "$rcfile")"
    fi
    export PATH="/opt/mac2n/bin:$PATH"

    if command -v mac2n &>/dev/null; then
        step_ok $n "mac2n command linked"
    else
        step_ok $n "mac2n installed to $LINK_PATH"
        printf "        ${YELLOW}Run:${RESET} source ~/%s\n" "$(basename "$rcfile")"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

show_help() {
    cat <<EOF
mac2n installer v${VERSION}

Usage:
    bash install.sh              Install mac2n (builds n2n from source)
    bash install.sh --uninstall  Remove mac2n, n2n binaries, and VPN services
    bash install.sh --help       Show this help
    bash install.sh --version    Print version and exit

Installs to: $INSTALL_DIR
Links to:    $LINK_PATH
EOF
}

main() {
    case "${1:-}" in
        --uninstall)  do_uninstall ;;
        --help|-h)    show_help; exit 0 ;;
        --version)    echo "mac2n installer v${VERSION}"; exit 0 ;;
        "")           ;; # no arg — proceed with install
        *)
            printf "${RED}Unknown option: %s${RESET}\n" "$1" >&2
            show_help
            exit 1
            ;;
    esac

    echo ""
    printf "  ${BOLD}mac2n installer${RESET} ${DIM}v${VERSION}${RESET}\n"
    echo ""

    if ! curl -fsS --head --max-time 5 https://github.com &>/dev/null; then
        printf "  ${RED}✗${RESET} No internet connection (cannot reach github.com)\n"
        exit 1
    fi

    ensure_xcode
    ensure_homebrew
    verify_clt
    fetch_repo
    build_and_install
    harden_and_verify
    link

    echo ""
    printf "  ${BOLD}mac2n installed successfully${RESET}\n"
    echo ""
    printf "    ${CYAN}mac2n${RESET}          interactive menu\n"
    printf "    ${CYAN}mac2n help${RESET}     full command reference\n"
    echo ""
}

main "$@"
