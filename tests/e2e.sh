#!/usr/bin/env bash
set -euo pipefail

# End-to-end test: uninstall → fresh install → verify mac2n is reachable
# Requires: macOS, internet, sudo access, Xcode CLT, Homebrew
# Run: sudo bash tests/e2e.sh (from repo root)

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.0.0-dev")

# When run via `sudo bash test-e2e.sh`, resolve the real (non-root) user
if [[ "$(id -u)" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(eval echo "~$REAL_USER")
    REAL_SHELL=$(dscl . -read "/Users/$REAL_USER" UserShell 2>/dev/null | awk '{print $2}')
    REAL_SHELL="${REAL_SHELL:-/bin/zsh}"
else
    REAL_USER="$(whoami)"
    REAL_HOME="$HOME"
    REAL_SHELL="${SHELL:-/bin/zsh}"
fi

INSTALL_DIR="$REAL_HOME/.mac2n"
LINK_PATH="/opt/mac2n/bin/mac2n"
PREFIX="/opt/mac2n"

run_as_user() {
    if [[ "$(id -u)" -eq 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$REAL_USER" -- "$@"
    else
        "$@"
    fi
}

source "$SCRIPT_DIR/tests/framework.sh"

# ── Display (override framework formatting for E2E style) ────────────────────

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    BOLD='\033[1m'  DIM='\033[2m'  RESET='\033[0m'
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m'
else
    BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW='' CYAN=''
fi

header()  { printf "\n${BOLD}${CYAN}▸ %s${RESET}\n" "$1"; }
pass()    { PASSED=$((PASSED + 1)); printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
fail()    { FAILED=$((FAILED + 1)); FAILURES+=("$1"); printf "  ${RED}✗${RESET} %s\n" "$1"; }
skip()    { SKIPPED=$((SKIPPED + 1)); printf "  ${YELLOW}–${RESET} %s (skipped)\n" "$1"; }
info()    { printf "  ${DIM}%s${RESET}\n" "$1"; }

# ── Prerequisites ────────────────────────────────────────────────────────────

header "Prerequisites"

if ! curl -fsS --head --max-time 5 https://github.com &>/dev/null; then
    fail "Internet connectivity (cannot reach github.com)"
    printf "\n${RED}Cannot proceed without internet. Aborting.${RESET}\n"
    exit 1
fi
pass "Internet connectivity"

if ! command -v brew &>/dev/null; then
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$p" ]]; then
            eval "$("$p" shellenv)"
            break
        fi
    done
fi
if command -v brew &>/dev/null; then
    pass "Homebrew available"
else
    fail "Homebrew not found"
    printf "\n${RED}Homebrew is required. Aborting.${RESET}\n"
    exit 1
fi

if xcode-select -p &>/dev/null; then
    pass "Xcode Command Line Tools"
else
    fail "Xcode Command Line Tools not installed"
    printf "\n${RED}Install with: xcode-select --install. Aborting.${RESET}\n"
    exit 1
fi

if sudo -n true 2>/dev/null; then
    pass "sudo access (cached)"
else
    info "sudo access required — you may be prompted"
    sudo -v
    pass "sudo access (granted)"
fi

# Keep sudo alive during test
while sudo -n true 2>/dev/null; do sleep 50; done &
SUDO_PID=$!
trap "kill $SUDO_PID 2>/dev/null || true" EXIT

# ── Phase 1: Clean uninstall ─────────────────────────────────────────────────

header "Phase 1: Clean uninstall"

info "Removing any existing installation to test from scratch..."

for plist in /Library/LaunchDaemons/org.ntop.n2n-*.plist; do
    [[ -f "$plist" ]] || continue
    label=$(basename "$plist" .plist)
    sudo launchctl bootout "system/$label" 2>/dev/null || \
        sudo launchctl unload "$plist" 2>/dev/null || true
    sudo rm -f "$plist"
done

for bin in "$PREFIX/sbin/edge" "$PREFIX/sbin/supernode"; do
    if [[ -f "$bin" ]]; then
        local_fw="/usr/libexec/ApplicationFirewall/socketfilterfw"
        [[ -x "$local_fw" ]] && sudo "$local_fw" --remove "$bin" 2>/dev/null || true
        sudo rm -f "$bin"
    fi
done

sudo rm -rf "$PREFIX/lib" "$PREFIX/share" 2>/dev/null || true

for link in /opt/mac2n/bin/mac2n /usr/local/bin/mac2n; do
    [[ -L "$link" ]] && sudo rm -f "$link"
done

[[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"

sudo rm -rf "$PREFIX/bin" 2>/dev/null || true
rmdir "$PREFIX/sbin" 2>/dev/null || true
rmdir "$PREFIX" 2>/dev/null || true

for rcfile in "$REAL_HOME/.zshrc" "$REAL_HOME/.bash_profile" "$REAL_HOME/.bashrc"; do
    [[ -f "$rcfile" ]] || continue
    if grep -q '/opt/mac2n/bin' "$rcfile" 2>/dev/null; then
        sed -i '' '\|/opt/mac2n/bin|d' "$rcfile"
    fi
done

export PATH="${PATH//:\/opt\/mac2n\/bin/}"

if ! command -v mac2n &>/dev/null && [[ ! -f "$LINK_PATH" ]] && [[ ! -d "$INSTALL_DIR" ]]; then
    pass "Clean uninstall complete"
else
    fail "Uninstall left artifacts behind"
    command -v mac2n &>/dev/null && info "mac2n still in PATH: $(command -v mac2n)"
    [[ -f "$LINK_PATH" ]] && info "symlink still exists: $LINK_PATH"
    [[ -d "$INSTALL_DIR" ]] && info "install dir still exists: $INSTALL_DIR"
fi

# ── Phase 2: Fresh install from local repo ───────────────────────────────────

header "Phase 2: Fresh install (build from local source)"

info "Copying repo to $INSTALL_DIR..."
run_as_user cp -R "$SCRIPT_DIR" "$INSTALL_DIR"

cd "$INSTALL_DIR"

info "Step 1/4: Installing build dependencies..."
if run_as_user bash ./build.sh deps 2>&1 | sed "s/^/    /"; then
    pass "build.sh deps"
else
    fail "build.sh deps"
fi

info "Step 2/4: Preparing source..."
if run_as_user bash ./build.sh source 2>&1 | sed "s/^/    /"; then
    pass "build.sh source"
else
    fail "build.sh source"
fi

info "Step 3/4: Building n2n (this takes a minute or two)..."
if run_as_user bash ./build.sh build 2>&1 | sed "s/^/    /"; then
    pass "build.sh build"
else
    fail "build.sh build"
fi

info "Step 4/4: Installing to $PREFIX..."
if bash ./build.sh install 2>&1 | sed "s/^/    /"; then
    pass "build.sh install"
else
    fail "build.sh install"
fi

# ── Phase 3: Harden & verify binaries ────────────────────────────────────────

header "Phase 3: Harden and verify binaries"

if bash ./build.sh harden 2>&1 | sed "s/^/    /"; then
    pass "build.sh harden (sign + firewall)"
else
    fail "build.sh harden"
fi

if bash ./build.sh verify 2>&1 | sed "s/^/    /"; then
    pass "build.sh verify (smoke test)"
else
    fail "build.sh verify"
fi

# ── Phase 4: Link mac2n command ──────────────────────────────────────────────

header "Phase 4: Link mac2n command"

local_target="$INSTALL_DIR/wizard.sh"
[[ -x "$local_target" ]] || chmod +x "$local_target"

link_dir="$(dirname "$LINK_PATH")"
[[ -d "$link_dir" ]] || sudo mkdir -p "$link_dir"
sudo ln -sf "$local_target" "$LINK_PATH"

[[ -L /usr/local/bin/mac2n ]] && sudo rm -f /usr/local/bin/mac2n

rcfile="$REAL_HOME/.zshrc"
[[ "$(basename "$REAL_SHELL")" == "bash" ]] && rcfile="$REAL_HOME/.bash_profile"
if ! grep -q '/opt/mac2n/bin' "$rcfile" 2>/dev/null; then
    echo 'export PATH="/opt/mac2n/bin:$PATH"' >> "$rcfile"
fi
export PATH="/opt/mac2n/bin:$PATH"

pass "Symlink created and PATH updated"

# ── Phase 5: Verify mac2n is reachable ───────────────────────────────────────

header "Phase 5: Verify mac2n is reachable"

assert_file_exists "Symlink file exists at $LINK_PATH" "$LINK_PATH"
assert_symlink_target "Symlink points to wizard.sh" "$LINK_PATH" "$local_target"
assert_executable "Symlink target is executable" "$local_target"
assert_command_exists "mac2n found in PATH" "mac2n"

resolved_path="$(command -v mac2n 2>/dev/null || echo "")"
assert_eq "mac2n resolves to $LINK_PATH" "$LINK_PATH" "$resolved_path"

assert_command_runs "mac2n --version runs" mac2n --version
assert_output_contains "mac2n --version outputs version string" "mac2n v" mac2n --version
assert_output_contains "mac2n --version matches VERSION file" "mac2n v${VERSION}" mac2n --version

assert_command_runs "mac2n help runs" mac2n help

# ── Phase 6: Verify installed binaries ───────────────────────────────────────

header "Phase 6: Verify installed binaries"

assert_file_exists "edge binary exists" "$PREFIX/sbin/edge"
assert_executable "edge binary is executable" "$PREFIX/sbin/edge"
assert_command_runs "edge --help runs" "$PREFIX/sbin/edge" --help

assert_file_exists "supernode binary exists" "$PREFIX/sbin/supernode"
assert_executable "supernode binary is executable" "$PREFIX/sbin/supernode"
assert_command_runs "supernode --help runs" "$PREFIX/sbin/supernode" --help

assert_file_exists "wait-for-network.sh installed" "$PREFIX/bin/wait-for-network.sh"
assert_executable "wait-for-network.sh is executable" "$PREFIX/bin/wait-for-network.sh"

# Verify bundled OpenSSL
if ls "$PREFIX/lib/n2n/"libcrypto.*.dylib &>/dev/null; then
    pass "Bundled libcrypto dylib present"
    edge_linked=$(otool -L "$PREFIX/sbin/edge" 2>/dev/null | grep 'libcrypto' | head -1 | awk '{print $1}')
    if [[ "$edge_linked" == "$PREFIX/lib/n2n/"* ]]; then
        pass "edge links to bundled libcrypto"
    else
        fail "edge links to $edge_linked instead of bundled copy"
    fi
else
    skip "Bundled libcrypto (OpenSSL may be statically linked)"
fi

# ── Phase 7: Verify fresh shell picks up mac2n ──────────────────────────────

header "Phase 7: Verify mac2n reachable in fresh shell"

shell_bin="$(basename "$REAL_SHELL")"
if [[ "$shell_bin" == "zsh" ]] || [[ "$shell_bin" == "bash" ]]; then
    fresh_check=$(run_as_user "$REAL_SHELL" -l -c "command -v mac2n" 2>/dev/null || echo "")
    if [[ "$fresh_check" == "$LINK_PATH" ]]; then
        pass "mac2n reachable in fresh login $shell_bin shell"
    else
        fail "mac2n not found in fresh login $shell_bin shell (got: '$fresh_check')"
        info "Check that /opt/mac2n/bin is in PATH in your shell profile"
    fi

    fresh_version=$(run_as_user "$REAL_SHELL" -l -c "mac2n --version" 2>/dev/null || echo "")
    assert_eq "mac2n --version in fresh shell" "mac2n v${VERSION}" "$fresh_version"
else
    skip "Fresh shell test (unsupported shell: $shell_bin)"
fi

# ── Phase 8: Verify wizard.sh detect_binaries works ─────────────────────────

header "Phase 8: Verify wizard detects binaries via status"

status_output=$(mac2n status 2>&1) || true
if echo "$status_output" | grep -q "edge:.*$PREFIX/sbin/edge"; then
    pass "wizard detects edge binary at $PREFIX/sbin/edge"
else
    fail "wizard did not detect edge binary in status output"
    info "status output: $status_output"
fi

if echo "$status_output" | grep -q "supernode:.*$PREFIX/sbin/supernode"; then
    pass "wizard detects supernode binary at $PREFIX/sbin/supernode"
else
    fail "wizard did not detect supernode binary in status output"
    info "status output: $status_output"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

TOTAL=$((PASSED + FAILED + SKIPPED))

echo ""
printf "${BOLD}════════════════════════════════════════════════════════════${RESET}\n"
printf "${BOLD}  Test Results${RESET}  (mac2n v${VERSION})\n"
printf "${BOLD}════════════════════════════════════════════════════════════${RESET}\n"
printf "  ${GREEN}Passed:${RESET}  %d\n" "$PASSED"
printf "  ${RED}Failed:${RESET}  %d\n" "$FAILED"
printf "  ${YELLOW}Skipped:${RESET} %d\n" "$SKIPPED"
printf "  Total:   %d\n" "$TOTAL"
printf "${BOLD}════════════════════════════════════════════════════════════${RESET}\n"

if (( FAILED > 0 )); then
    echo ""
    printf "${RED}${BOLD}  Failed tests:${RESET}\n"
    for f in "${FAILURES[@]}"; do
        printf "  ${RED}✗${RESET} %s\n" "$f"
    done
    echo ""
    exit 1
fi

echo ""
printf "${GREEN}${BOLD}  All tests passed!${RESET}\n"
echo ""
exit 0
