#!/usr/bin/env bash
# tests/framework.sh — Assertion helpers, counters, summary reporter
# Sourced by both unit and E2E tests.

[[ -n "${_TEST_FRAMEWORK_LOADED:-}" ]] && return 0
_TEST_FRAMEWORK_LOADED=1

PASSED=0
FAILED=0
SKIPPED=0
FAILURES=()

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    T_BOLD='\033[1m'     T_DIM='\033[2m'      T_RESET='\033[0m'
    T_RED='\033[0;31m'   T_GREEN='\033[0;32m'  T_YELLOW='\033[0;33m'
    T_CYAN='\033[0;36m'
else
    T_BOLD='' T_DIM='' T_RESET='' T_RED='' T_GREEN='' T_YELLOW='' T_CYAN=''
fi

header() { printf "\n${T_CYAN}${T_BOLD}── %s ──${T_RESET}\n" "$1"; }
pass()   { PASSED=$((PASSED + 1)); printf "  ${T_GREEN}✓${T_RESET} %s\n" "$1"; }
fail()   { FAILED=$((FAILED + 1)); FAILURES+=("$1"); printf "  ${T_RED}✗${T_RESET} %s\n" "$1"; }
skip()   { SKIPPED=$((SKIPPED + 1)); printf "  ${T_YELLOW}○${T_RESET} %s (skipped)\n" "$1"; }
info()   { printf "  ${T_DIM}%s${T_RESET}\n" "$1"; }

assert_eq() {
    local desc="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_match() {
    local desc="$1" actual="$2" pattern="$3"
    if [[ "$actual" =~ $pattern ]]; then
        pass "$desc"
    else
        fail "$desc (expected match '$pattern', got '$actual')"
    fi
}

assert_exit_success() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc (exit code $?)"
    fi
}

assert_exit_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc (expected failure, got success)"
    else
        pass "$desc"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (file not found: $path)"
    fi
}

assert_executable() {
    local desc="$1" path="$2"
    if [[ -x "$path" ]]; then
        pass "$desc"
    else
        fail "$desc (not executable: $path)"
    fi
}

assert_symlink_target() {
    local desc="$1" link="$2" expected="$3"
    if [[ -L "$link" ]]; then
        local actual
        actual=$(readlink "$link")
        if [[ "$actual" == "$expected" ]]; then
            pass "$desc"
        else
            fail "$desc (symlink target: '$actual', expected '$expected')"
        fi
    else
        fail "$desc (not a symlink: $link)"
    fi
}

assert_command_exists() {
    local desc="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        pass "$desc"
    else
        fail "$desc (command not found: $cmd)"
    fi
}

assert_command_runs() {
    local desc="$1"
    shift
    local rc=0
    "$@" &>/dev/null || rc=$?
    if (( rc != 126 && rc != 127 )); then
        pass "$desc"
    else
        fail "$desc (exit $rc — command not found or not executable)"
    fi
}

assert_output_contains() {
    local desc="$1" pattern="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$pattern"; then
        pass "$desc"
    else
        fail "$desc (output does not contain '$pattern')"
    fi
}

test_summary() {
    local total=$((PASSED + FAILED + SKIPPED))
    echo ""
    printf "${T_BOLD}── Results ──${T_RESET}\n"
    printf "  ${T_GREEN}Passed:  %d${T_RESET}\n" "$PASSED"
    printf "  ${T_RED}Failed:  %d${T_RESET}\n" "$FAILED"
    printf "  ${T_YELLOW}Skipped: %d${T_RESET}\n" "$SKIPPED"
    printf "  Total:   %d\n" "$total"

    if (( FAILED > 0 )); then
        echo ""
        printf "${T_RED}${T_BOLD}Failures:${T_RESET}\n"
        for f in "${FAILURES[@]}"; do
            printf "  ${T_RED}• %s${T_RESET}\n" "$f"
        done
        return 1
    fi
    return 0
}
