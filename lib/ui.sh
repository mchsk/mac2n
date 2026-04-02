#!/usr/bin/env bash
# lib/ui.sh — Terminal I/O: print_*, ask_*, pick_instance
# Depends on: lib/core.sh

[[ -n "${_LIB_UI_LOADED:-}" ]] && return 0
[[ -n "${_LIB_CORE_LOADED:-}" ]] || { echo "lib/ui.sh: lib/core.sh must be loaded first" >&2; exit 1; }
_LIB_UI_LOADED=1

print_header() {
    local width=60
    echo ""
    printf "${CYAN}"
    printf '  ╭'; printf '─%.0s' $(seq 1 $width); printf '╮\n'
    local pad_l=$(( (width - ${#1}) / 2 ))
    local pad_r=$(( width - ${#1} - pad_l ))
    printf '  │%*s%s%*s│\n' "$pad_l" "" "$1" "$pad_r" ""
    if [[ -n "${2:-}" ]]; then
        pad_l=$(( (width - ${#2}) / 2 ))
        pad_r=$(( width - ${#2} - pad_l ))
        printf '  │%*s%s%*s│\n' "$pad_l" "" "$2" "$pad_r" ""
    fi
    printf '  ╰'; printf '─%.0s' $(seq 1 $width); printf '╯\n'
    printf "${RESET}"
    echo ""
}

print_section() {
    echo ""
    printf "  ${WHITE}%s${RESET}\n" "$1"
    printf "  ${GRAY}"
    printf '─%.0s' $(seq 1 52)
    printf "${RESET}\n"
}

print_status() {
    local symbol=$1 msg=$2
    printf "  %b %b\n" "$symbol" "$msg"
}

print_info() {
    printf "  ${GRAY}%s${RESET}\n" "$1"
}

print_box() {
    local title=$1
    shift
    local width=56
    local content_width=$((width - 1))

    for line in "$@"; do
        if (( ${#line} + 2 > width )); then
            width=$((${#line} + 3))
            content_width=$((width - 1))
        fi
    done

    local border_fill=$((width - ${#title} - 3))
    if (( border_fill < 1 )); then border_fill=1; fi

    echo ""
    printf "  ${CYAN}┌─ %s " "$title"
    printf '─%.0s' $(seq 1 $border_fill)
    printf "┐${RESET}\n"
    for line in "$@"; do
        printf "  ${CYAN}│${RESET} %-*s ${CYAN}│${RESET}\n" "$content_width" "$line"
    done
    printf "  ${CYAN}└"
    printf '─%.0s' $(seq 1 $((width + 1)))
    printf "┘${RESET}\n"
}

ask() {
    local prompt=$1 default=${2:-} var_name=$3
    local input
    if [[ -n "$default" ]]; then
        printf "  ${SYM_ARROW} ${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$prompt" "$default"
    else
        printf "  ${SYM_ARROW} ${BOLD}%s${RESET}: " "$prompt"
    fi
    if ! read -r input; then
        _STDIN_EOF=true
        input="$default"
    fi
    input="${input:-$default}"
    printf -v "$var_name" '%s' "$input"
}

ask_password() {
    local prompt=$1 var_name=$2
    local input
    printf "  ${SYM_LOCK} ${BOLD}%s${RESET}: " "$prompt"
    if ! read -rs input; then
        _STDIN_EOF=true
        input=""
    fi
    echo ""
    printf -v "$var_name" '%s' "$input"
}

ask_yesno() {
    local prompt=$1 default=${2:-y}
    local hint input
    if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    printf "  ${SYM_ARROW} ${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$prompt" "$hint"
    if ! read -r input; then
        input="$default"
    fi
    input="${input:-$default}"
    [[ "$input" =~ ^[Yy] ]]
}

ask_choice() {
    local prompt=$1 var_name=$2
    shift 2
    local options=("$@")
    local i=1

    echo ""
    for opt in "${options[@]}"; do
        printf "    ${WHITE}%d)${RESET} %s\n" "$i" "$opt"
        i=$((i + 1))
    done
    echo ""

    local choice
    while true; do
        printf "  ${SYM_ARROW} ${BOLD}%s${RESET} ${DIM}[1-%d]${RESET}: " "$prompt" "${#options[@]}"
        if ! read -r choice; then
            echo ""
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            printf -v "$var_name" '%s' "$choice"
            return
        fi
        printf "  ${RED}Invalid choice. Enter a number 1-%d.${RESET}\n" "${#options[@]}"
    done
}

pick_instance() {
    local action_label="${1:-Select}"

    local names=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && names+=("$name")
    done < <(list_instance_names)

    if (( ${#names[@]} == 0 )); then
        print_status "$SYM_DOT" "No instances configured." >&2
        return 1
    fi

    if (( ${#names[@]} == 1 )); then
        printf "  ${DIM}Auto-selected instance: %s${RESET}\n" "${names[0]}" >&2
        echo "${names[0]}"
        return
    fi

    echo "" >&2
    local i=1
    local name
    for name in "${names[@]}"; do
        local status
        status="$(instance_status_plain "$name")"
        printf "    ${WHITE}%d)${RESET} %s ${DIM}(%s)${RESET}\n" "$i" "$name" "$status" >&2
        i=$((i + 1))
    done
    echo "" >&2

    local choice
    while true; do
        printf "  ${SYM_ARROW} ${BOLD}%s which instance?${RESET} ${DIM}[1-%d]${RESET}: " "$action_label" "${#names[@]}" >&2
        if ! read -r choice; then
            echo "" >&2
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            echo "${names[$((choice - 1))]}"
            return
        fi
        printf "  ${RED}Invalid choice.${RESET}\n" >&2
    done
}
