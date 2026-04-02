#!/usr/bin/env bash
# lib/presets.sh — Use-case preset definitions and application
# Depends on: lib/core.sh, lib/ui.sh, lib/edge_model.sh

[[ -n "${_LIB_PRESETS_LOADED:-}" ]] && return 0
[[ -n "${_LIB_CORE_LOADED:-}" ]] || { echo "lib/presets.sh: lib/core.sh must be loaded first" >&2; exit 1; }
_LIB_PRESETS_LOADED=1

USECASE=""

select_usecase() {
    print_section "Use Case Preset"
    print_info "Choose a preset for smart defaults, or go fully custom."

    ask_choice "Select preset" USECASE \
        "Home VPN        — Private network for your personal devices" \
        "Remote Access   — Reach home/office from anywhere" \
        "Site-to-Site    — Bridge two separate LANs" \
        "Gaming / LAN    — Low-latency direct P2P, minimal overhead" \
        "IoT Mesh        — Lightweight encrypted mesh for IoT devices" \
        "Custom          — Full manual configuration" || return 1
}

apply_usecase_defaults() {
    case $USECASE in
        1) # Home VPN
            EDGE_COMMUNITY="home"
            EDGE_CIPHER="3"
            EDGE_IP="10.88.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="n"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="$(hostname -s)"
            ;;
        2) # Remote Access
            EDGE_COMMUNITY="remote"
            EDGE_CIPHER="4"
            EDGE_IP="10.90.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="y"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="$(hostname -s)"
            ;;
        3) # Site-to-Site
            EDGE_COMMUNITY="site2site"
            EDGE_CIPHER="3"
            EDGE_IP="10.100.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="y"
            EDGE_MULTICAST="y"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="site-$(hostname -s)"
            ;;
        4) # Gaming / LAN
            EDGE_COMMUNITY="lan"
            EDGE_CIPHER="1"
            EDGE_IP="10.77.0.1"
            EDGE_CIDR="24"
            EDGE_MTU="1400"
            EDGE_ROUTING="n"
            EDGE_MULTICAST="y"
            EDGE_COMPRESSION=""
            EDGE_DESCRIPTION="$(hostname -s)"
            EDGE_SN_SELECT="rtt"
            ;;
        5) # IoT Mesh
            EDGE_COMMUNITY="iot"
            EDGE_CIPHER="5"
            EDGE_IP="10.66.0.1"
            EDGE_CIDR="16"
            EDGE_MTU="1000"
            EDGE_ROUTING="y"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION="1"
            EDGE_DESCRIPTION="iot-$(hostname -s)"
            ;;
        6) # Custom
            EDGE_COMMUNITY=""
            EDGE_KEY=""
            EDGE_CIPHER="3"
            EDGE_IP=""
            EDGE_CIDR="24"
            EDGE_MTU="1290"
            EDGE_ROUTING="n"
            EDGE_MULTICAST="n"
            EDGE_COMPRESSION=""
            ;;
    esac
}
