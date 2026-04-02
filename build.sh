#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.0.0-dev")
REPO_URL="https://github.com/ntop/n2n.git"
COMMIT="6a64e72dc6cdfac818ffb210515b17cfa70f4bb3"
BUILD_DIR="${SCRIPT_DIR}/n2n-src"
PREFIX="${PREFIX:-/opt/mac2n}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# ── Display ───────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    BOLD='\033[1m'  DIM='\033[2m'  RESET='\033[0m'
    RED='\033[0;31m' GREEN='\033[0;32m' CYAN='\033[0;36m'
else
    BOLD='' DIM='' RESET='' RED='' GREEN='' CYAN=''
fi

_info()  { printf "${CYAN}==>${RESET} ${BOLD}%s${RESET}\n" "$1"; }
_ok()    { printf "${GREEN}==>${RESET} ${BOLD}%s${RESET}\n" "$1"; }
_err()   { printf "${RED}Error:${RESET} %s\n" "$1" >&2; }
_detail() { printf "    %b\n" "$1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

Commands:
    deps        Install build dependencies via Homebrew
    source      Fetch n2n source (submodule or clone)
    build       Configure and build n2n (autotools)
    build-cmake Configure and build n2n (CMake)
    install     Install edge, supernode, and tools to $PREFIX
    harden      Ad-hoc sign binaries and add firewall exceptions
    verify      Smoke-test that edge and supernode execute
    clean       Clean build artifacts (keeps source)
    all         deps + source + build + install + harden + verify (default)

Environment variables:
    PREFIX      Installation prefix (default: /opt/mac2n)
    JOBS        Parallel make jobs (default: CPU count)
EOF
}

do_deps() {
    _info "Installing build dependencies..."
    if ! command -v brew &>/dev/null; then
        _err "Homebrew is required. Install from https://brew.sh"
        exit 1
    fi
    HOMEBREW_NO_AUTO_UPDATE=1 brew install --quiet autoconf automake libtool openssl@3 cmake
    _ok "Dependencies installed"
}

do_source() {
    if [ -d "$BUILD_DIR/.git" ]; then
        _info "Source already present at $BUILD_DIR"
        cd "$BUILD_DIR"
        local current
        current=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [ "$current" != "$COMMIT" ]; then
            _info "Checking out pinned commit..."
            git fetch origin --quiet 2>/dev/null || true
            git checkout "$COMMIT" --quiet
        fi
    elif [ -f "$SCRIPT_DIR/.gitmodules" ]; then
        _info "Initializing n2n submodule..."
        cd "$SCRIPT_DIR"
        git submodule update --init --quiet n2n-src
        cd "$BUILD_DIR"
    else
        _info "Cloning n2n (standalone mode)..."
        git clone --quiet "$REPO_URL" "$BUILD_DIR"
        cd "$BUILD_DIR"
        git checkout "$COMMIT" --quiet
    fi
    _ok "Using n2n at commit ${COMMIT:0:10}"
}

do_build() {
    cd "$BUILD_DIR"

    if [ ! -f configure ]; then
        if [ ! -f autogen.sh ]; then
            _err "Neither configure nor autogen.sh found — source may be incomplete."
            exit 1
        fi
        _info "Running autogen.sh..."
        bash ./autogen.sh
        if [ ! -f configure ]; then
            _err "autogen.sh did not produce a configure script."
            exit 1
        fi
    fi

    if [ ! -f Makefile ]; then
        _info "Running configure..."
        ./configure \
            --with-openssl \
            CFLAGS="-I$(brew --prefix openssl@3)/include" \
            LDFLAGS="-L$(brew --prefix openssl@3)/lib"
    fi

    _info "Building n2n with $JOBS parallel jobs..."
    make -j"$JOBS"
    _ok "Build complete"
    _detail "edge:      $BUILD_DIR/edge"
    _detail "supernode:  $BUILD_DIR/supernode"
}

do_build_cmake() {
    cd "$BUILD_DIR"
    local cmake_build="$BUILD_DIR/build"

    mkdir -p "$cmake_build"
    cd "$cmake_build"

    _info "Configuring with CMake..."
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DN2N_OPTION_USE_OPENSSL=ON \
        -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
        -DCMAKE_BUILD_TYPE=Release

    _info "Building n2n with $JOBS parallel jobs..."
    make -j"$JOBS"
    _ok "Build complete"
    _detail "edge:      $cmake_build/edge"
    _detail "supernode:  $cmake_build/supernode"
}

do_install() {
    cd "$BUILD_DIR"

    _info "Installing to $PREFIX..."
    sudo mkdir -p "${PREFIX}/sbin" "${PREFIX}/share/man/man1" "${PREFIX}/share/man/man8"

    if [ -d "$BUILD_DIR/build" ] && [ -f "$BUILD_DIR/build/edge" ]; then
        cd "$BUILD_DIR/build"
        sudo make install DESTDIR="" \
            SBINDIR="${PREFIX}/sbin" \
            MANDIR="${PREFIX}/share/man"
    else
        sudo make install SBINDIR="${PREFIX}/sbin" \
            MANDIR="${PREFIX}/share/man"
    fi

    do_bundle_openssl

    # Install helper scripts
    sudo mkdir -p "${PREFIX}/bin"
    if [ -f "$SCRIPT_DIR/wait-for-network.sh" ]; then
        sudo cp "$SCRIPT_DIR/wait-for-network.sh" "${PREFIX}/bin/wait-for-network.sh"
        sudo chmod 755 "${PREFIX}/bin/wait-for-network.sh"
    fi

    _ok "Installed to ${PREFIX}/sbin"
}

do_bundle_openssl() {
    local lib_dir="${PREFIX}/lib/n2n"
    local edge_bin="${PREFIX}/sbin/edge"

    [ -f "$edge_bin" ] || return

    local linked_path
    linked_path=$(otool -L "$edge_bin" 2>/dev/null \
        | grep 'libcrypto\.' | head -1 | awk '{print $1}')

    if [ -z "$linked_path" ] || [ ! -f "$linked_path" ]; then
        _detail "(skipping dylib bundle — linked libcrypto not found)"
        return
    fi

    local dylib_name
    dylib_name="$(basename "$linked_path")"

    sudo mkdir -p "$lib_dir"
    sudo cp "$linked_path" "$lib_dir/$dylib_name"
    sudo chmod 644 "$lib_dir/$dylib_name"

    local dest="$lib_dir/$dylib_name"
    for bin in "${PREFIX}/sbin/edge" "${PREFIX}/sbin/supernode"; do
        [ -f "$bin" ] || continue
        local name
        name="$(basename "$bin")"
        if ! sudo install_name_tool -change "$linked_path" "$dest" "$bin" 2>&1; then
            _err "Failed to relink $name to bundled OpenSSL at $dest"
            _detail "Fix manually: sudo install_name_tool -change \"$linked_path\" \"$dest\" \"$bin\""
            exit 1
        fi
    done

    # Verify the relink succeeded
    for bin in "${PREFIX}/sbin/edge" "${PREFIX}/sbin/supernode"; do
        [ -f "$bin" ] || continue
        local actual_path
        actual_path=$(otool -L "$bin" 2>/dev/null | grep 'libcrypto\.' | head -1 | awk '{print $1}')
        if [ "$actual_path" != "$dest" ]; then
            _err "$(basename "$bin") still links to $actual_path instead of $dest"
            exit 1
        fi
    done

    _detail "$dylib_name bundled to $lib_dir (verified)"
}

do_harden() {
    local bins=("${PREFIX}/sbin/edge" "${PREFIX}/sbin/supernode")
    local fw="/usr/libexec/ApplicationFirewall/socketfilterfw"

    _info "Signing binaries and configuring firewall..."

    for bin in "${bins[@]}"; do
        [ -f "$bin" ] || continue
        local name
        name="$(basename "$bin")"

        sudo xattr -dr com.apple.quarantine "$bin" 2>/dev/null || true

        local sign_err
        if ! sign_err=$(sudo codesign --force --sign - "$bin" 2>&1); then
            _detail "$name: ${RED}WARNING${RESET} — codesign failed"
            [[ -n "$sign_err" ]] && _detail "  ${DIM}${sign_err}${RESET}"
            _detail "  ${DIM}(fix: sudo codesign --force --sign - $bin)${RESET}"
        else
            local flags
            flags=$(codesign -d --verbose=2 "$bin" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)')
            if [[ "$flags" == *"linker-signed"* ]]; then
                _detail "$name: ${RED}WARNING${RESET} — still linker-signed after signing"
                _detail "  ${DIM}(fix: sudo codesign --force --sign - $bin)${RESET}"
            else
                _detail "$name: signed"
            fi
        fi

        if [ -x "$fw" ]; then
            sudo "$fw" --add "$bin" 2>/dev/null || true
            sudo "$fw" --unblockapp "$bin" 2>/dev/null || true
            _detail "$name: firewall allow-listed"
        fi
    done
}

do_verify() {
    _info "Verifying binaries..."
    local ok=true

    for bin in "${PREFIX}/sbin/edge" "${PREFIX}/sbin/supernode"; do
        [ -f "$bin" ] || continue
        local name
        name="$(basename "$bin")"

        # Run --help and check if the binary actually loaded and executed.
        # Exit 127 = command not found, 126 = cannot execute (permission/format).
        # Any other code (including 1 from --help) means the binary works.
        local rc=0
        "$bin" --help &>/dev/null || rc=$?
        if (( rc != 127 && rc != 126 )); then
            _detail "$name: ok"
        else
            _detail "$name: ${RED}FAILED${RESET} — binary does not execute (exit $rc)"
            _detail "(check: otool -L $bin)"
            ok=false
        fi
    done

    if ! $ok; then
        _err "one or more binaries failed the smoke test."
        exit 1
    fi
}

do_clean() {
    if [ -d "$BUILD_DIR" ]; then
        _info "Cleaning build artifacts..."
        cd "$BUILD_DIR"
        make clean 2>/dev/null || true
        rm -rf build/ autom4te.cache/ config.log config.status Makefile
        _ok "Clean complete (source kept)"
    else
        _info "Nothing to clean."
    fi
}

do_all() {
    do_deps
    do_source
    do_build
    do_install
    do_harden
    do_verify
}

case "${1:-all}" in
    deps)         do_deps ;;
    source|clone) do_source ;;
    build)        do_build ;;
    build-cmake)  do_build_cmake ;;
    install)      do_install ;;
    harden|sign)  do_harden ;;
    verify|test)  do_verify ;;
    clean)        do_clean ;;
    all)          do_all ;;
    -h|--help)    usage ;;
    --version)    echo "mac2n-build v${VERSION}" ;;
    *)
        _err "Unknown command: $1"
        usage
        exit 1
        ;;
esac
