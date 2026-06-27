#!/bin/bash
#
# Kali Linux IP & MAC Changer
# - Menu driven with whiptail (terminal UI)
# - Desktop launcher ready
# - Options:
#   1. Set custom IP (reuses current subnet/gateway)
#   2. Set custom MAC
#   3. Random MAC + renew IP via NetworkManager DHCP (one-shot)
#   4. Reset to real (original) MAC + network config
#   7. Rolling mode: continuously pick new random MAC+IP on a timer until stopped (Ctrl+C)
#
# SECURITY:
#   - Never hardcodes your sudo password.
#   - Prompts via whiptail password box only when changes are needed.
#   - Password lives only in memory for this script run.
#
# RECOMMENDED (optional, for no password prompts):
#   Run: sudo visudo
#   Add (replace 'will' with your username):
#     will ALL=(ALL) NOPASSWD: /usr/bin/macchanger, /usr/bin/nmcli, /usr/sbin/ip, /usr/bin/systemctl
#
# Usage:
#   ./ip-mac-changer.sh
#   Then create desktop launcher (script below will do it for you)
#

set -o pipefail

CONFIG_DIR="$HOME/.config/kali-ip-mac-changer"
ORIG_FILE="$CONFIG_DIR/original.conf"
SUDO_PASS=""
HAVE_SUDO_PASS=false
IFACE=""
CONN_NAME=""
TYPE=""
MAC_PROP="802-3-ethernet.cloned-mac-address"

# ---------- helpers ----------

die() {
  whiptail --title "Error" --msgbox "$1" 10 60
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# No protection logic (disabled per request)

detect_iface() {
  IFACE=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  if [ -z "$IFACE" ] || [ "$IFACE" = "lo" ]; then
    for cand in wlan1 wlan0 eth0 enp0s3 enp0s8 wlp2s0; do
      if ip link show "$cand" >/dev/null 2>&1; then
        IFACE="$cand"
        break
      fi
    done
  fi
  if [ -z "$IFACE" ]; then
    IFACE=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
  fi
  [ -z "$IFACE" ] && die "Could not detect a usable network interface."

  # No longer preferring non-protected cards (protection disabled)
}

detect_connection() {
  CONN_NAME=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
  if [ -z "$CONN_NAME" ] || [ "$CONN_NAME" = "--" ]; then
    CONN_NAME=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ":$IFACE:" | cut -d: -f1 | head -1)
  fi
  [ -z "$CONN_NAME" ] && CONN_NAME=$(nmcli -t -f NAME,DEVICE con show 2>/dev/null | grep ":$IFACE:" | cut -d: -f1 | head -1)
  [ -z "$CONN_NAME" ] && CONN_NAME=""

  TYPE=$(nmcli -g GENERAL.TYPE device show "$IFACE" 2>/dev/null || echo "ethernet")
  if [[ "$TYPE" == "wifi" || "$TYPE" == "802-11-wireless" ]]; then
    MAC_PROP="802-11-wireless.cloned-mac-address"
  else
    MAC_PROP="802-3-ethernet.cloned-mac-address"
  fi
}

init_original_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true

  if [ ! -f "$ORIG_FILE" ]; then
    detect_connection

    local m_orig
    local i_method i_addrs i_gw i_dns

    m_orig=$(nmcli -g "$MAC_PROP" con show "$CONN_NAME" 2>/dev/null || echo "")
    i_method=$(nmcli -g ipv4.method con show "$CONN_NAME" 2>/dev/null || echo "auto")
    i_addrs=$(nmcli -g ipv4.addresses con show "$CONN_NAME" 2>/dev/null || echo "")
    i_gw=$(nmcli -g ipv4.gateway con show "$CONN_NAME" 2>/dev/null || echo "")
    i_dns=$(nmcli -g ipv4.dns con show "$CONN_NAME" 2>/dev/null || echo "")

    cat > "$ORIG_FILE" <<EOF
IFACE=$IFACE
CONN_NAME=$CONN_NAME
TYPE=$TYPE
MAC_PROP=$MAC_PROP
ORIG_CLONED_MAC=$m_orig
ORIG_IPV4_METHOD=$i_method
ORIG_IPV4_ADDRESSES=$i_addrs
ORIG_IPV4_GATEWAY=$i_gw
ORIG_IPV4_DNS=$i_dns
EOF
    chmod 600 "$ORIG_FILE"
  else
    # shellcheck disable=SC1090
    source "$ORIG_FILE"
    # Re-detect in case interface changed since last save
    detect_connection
  fi
}

get_sudo_pass() {
  if $HAVE_SUDO_PASS; then
    return 0
  fi

  SUDO_PASS=$(whiptail --passwordbox "Sudo password required for network changes.\n\nInterface: $IFACE" 12 55 3>&1 1>&2 2>&3)
  local ret=$?
  if [ $ret -ne 0 ] || [ -z "$SUDO_PASS" ]; then
    whiptail --msgbox "Password entry cancelled." 8 40
    return 1
  fi

  # Validate
  if ! echo "$SUDO_PASS" | sudo -S -v --prompt="" 2>/dev/null; then
    whiptail --title "Authentication Failed" --msgbox "Incorrect sudo password or insufficient privileges." 8 50
    SUDO_PASS=""
    return 1
  fi

  HAVE_SUDO_PASS=true
  return 0
}

run_priv() {
  # Run a command with sudo, using cached password
  if ! $HAVE_SUDO_PASS; then
    get_sudo_pass || return 1
  fi
  echo "$SUDO_PASS" | sudo -S --prompt="" "$@"
}

show_status() {
  local cur_mac cur_ip cur_ip_full
  cur_mac=$(macchanger -s "$IFACE" 2>/dev/null | awk '/Current MAC:/ {print $3}' || echo "unknown")
  cur_ip_full=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}' || echo "none")
  cur_ip=$(echo "$cur_ip_full" | cut -d/ -f1)

  whiptail --title "Current Status - $IFACE" --msgbox \
"Interface : $IFACE
Connection: ${CONN_NAME:-unknown}

Current MAC : $cur_mac
Current IP  : ${cur_ip:-none}   ($cur_ip_full)

Permanent MAC (hardware) is shown by 'macchanger -s'." 14 60
}

validate_ip() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

validate_mac() {
  [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

set_custom_ip() {
  local new_ip prefix gw

  new_ip=$(whiptail --inputbox "Enter the new IP address you want:\n\nExample: 10.3.10.150" 12 55 3>&1 1>&2 2>&3) || return
  [ -z "$new_ip" ] && return

  if ! validate_ip "$new_ip"; then
    whiptail --msgbox "Invalid IP address format.\n\nUse dotted quad like 192.168.1.50" 9 50
    return
  fi

  # Grab current prefix + gateway from live system (works for both DHCP and static)
  prefix=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / { split($2,a,"/"); print a[2]; exit }')
  [ -z "$prefix" ] && prefix=24

  gw=$(ip route show default 2>/dev/null | awk '/^default via/ {print $3; exit}')
  if [ -z "$gw" ]; then
    gw=$(whiptail --inputbox "Gateway not auto-detected.\nEnter gateway IP:" 10 50 "10.3.10.1" 3>&1 1>&2 2>&3) || return
  fi

  if ! get_sudo_pass; then return; fi

  # Apply via NetworkManager (persistent to the connection profile)
  if ! run_priv nmcli con mod "$CONN_NAME" \
        ipv4.method manual \
        ipv4.addresses "$new_ip/$prefix" \
        ipv4.gateway "$gw" \
        ipv4.dns ""; then
    whiptail --msgbox "Failed to modify connection profile." 8 45
    return
  fi

  run_priv nmcli con up "$CONN_NAME" 2>/dev/null || true

  whiptail --msgbox "Custom IP applied successfully!\n\nIP: $new_ip/$prefix\nGateway: $gw\n\nNote: Connection profile was updated." 12 55
  show_status
}

set_custom_mac() {
  local new_mac

  new_mac=$(whiptail --inputbox "Enter new MAC address:\n\nFormat: 00:11:22:33:44:55\n(Use 02, 06, 0A or 0E as first byte for 'locally administered')" 12 60 3>&1 1>&2 2>&3) || return
  [ -z "$new_mac" ] && return

  if ! validate_mac "$new_mac"; then
    whiptail --msgbox "Invalid MAC address.\n\nMust be 6 pairs of hex digits separated by colons." 9 55
    return
  fi

  if ! get_sudo_pass; then return; fi

  # No protection checks

  whiptail --infobox "Taking $IFACE down to change MAC..." 6 50
  run_priv ip link set "$IFACE" down 2>/dev/null || true
  sleep 0.5

  # Use macchanger (most reliable for actual interface)
  local mc_out
  if ! mc_out=$(run_priv macchanger -m "$new_mac" "$IFACE" 2>&1); then
    run_priv ip link set "$IFACE" up 2>/dev/null || true
    whiptail --msgbox "macchanger failed to set MAC:\n\n$mc_out" 12 70
    return
  fi

  run_priv ip link set "$IFACE" up 2>/dev/null || true
  sleep 0.5

  # Also update NM profile so it stays happy
  run_priv nmcli con mod "$CONN_NAME" "$MAC_PROP" "$new_mac" 2>/dev/null || true
  run_priv nmcli con up "$CONN_NAME" 2>/dev/null || true

  whiptail --msgbox "MAC address changed!\n\nNew MAC: $new_mac" 9 45
  show_status
}

random_mac_and_ip() {
  if ! get_sudo_pass; then return; fi

  do_random_roll

  whiptail --msgbox "Random MAC + IP refresh complete.\n\nIf IP did not change, your DHCP server may have reserved it.\nYou can also choose option 4 then option 3 again." 12 60
  show_status
}

# Core randomization logic (no final user prompts).
# Assumes sudo password is already obtained via get_sudo_pass + HAVE_SUDO_PASS.
do_random_roll() {
  local rand_mac=""
  local quiet_rolling=false
  # Suppress whiptail progress boxes when called from rolling_mode (we print status to terminal instead)
  [ -n "${ROLLING_ACTIVE:-}" ] && quiet_rolling=true

  if ! $quiet_rolling; then
    whiptail --infobox "Taking $IFACE down for new random MAC..." 5 48 2>/dev/null || true
  fi
  run_priv ip link set "$IFACE" down 2>/dev/null || true
  sleep 0.6

  local mc_out
  if mc_out=$(run_priv macchanger -r "$IFACE" 2>&1); then
    rand_mac=$(macchanger -s "$IFACE" 2>/dev/null | awk '/Current MAC:/ {print $3}')
    run_priv ip link set "$IFACE" up 2>/dev/null || true
    sleep 0.4
  else
    run_priv ip link set "$IFACE" up 2>/dev/null || true
    sleep 0.5

    if run_priv nmcli con mod "$CONN_NAME" "$MAC_PROP" random 2>/dev/null; then
      rand_mac=$(nmcli -g "$MAC_PROP" con show "$CONN_NAME" 2>/dev/null || echo "random")
    else
      rand_mac="unknown"
    fi
  fi

  if [ -n "$rand_mac" ] && [ "$rand_mac" != "random" ]; then
    run_priv nmcli con mod "$CONN_NAME" "$MAC_PROP" "$rand_mac" 2>/dev/null || true
  fi

  # Cycle connection to obtain fresh DHCP IP with the new MAC
  if ! $quiet_rolling; then
    whiptail --infobox "Reconnecting for fresh DHCP IP..." 5 42 2>/dev/null || true
  fi
  run_priv nmcli device disconnect "$IFACE" 2>/dev/null || true
  sleep 2
  run_priv nmcli device connect "$IFACE" 2>/dev/null || true
  sleep 4
}

reset_to_real() {
  if ! get_sudo_pass; then return; fi

  whiptail --infobox "Resetting to original MAC and network configuration..." 6 55
  sleep 0.5

  # 1. Restore burned-in hardware MAC (needs interface down)
  # (no protection checks)
  run_priv ip link set "$IFACE" down 2>/dev/null || true
  sleep 0.4
  run_priv macchanger -p "$IFACE" 2>/dev/null || true
  run_priv ip link set "$IFACE" up 2>/dev/null || true
  sleep 0.4

  # 2. Restore original NM profile settings we captured at first run
  if [ -f "$ORIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ORIG_FILE"

    run_priv nmcli con mod "$CONN_NAME" ipv4.method "${ORIG_IPV4_METHOD:-auto}" 2>/dev/null || true

    if [ -n "${ORIG_IPV4_ADDRESSES:-}" ] && [ "${ORIG_IPV4_ADDRESSES}" != "--" ] && [ "${ORIG_IPV4_ADDRESSES}" != "" ]; then
      run_priv nmcli con mod "$CONN_NAME" ipv4.addresses "${ORIG_IPV4_ADDRESSES}" 2>/dev/null || true
    else
      run_priv nmcli con mod "$CONN_NAME" ipv4.addresses "" 2>/dev/null || true
    fi

    run_priv nmcli con mod "$CONN_NAME" ipv4.gateway "${ORIG_IPV4_GATEWAY:-}" 2>/dev/null || true
    run_priv nmcli con mod "$CONN_NAME" ipv4.dns "${ORIG_IPV4_DNS:-}" 2>/dev/null || true

    local clone_val="${ORIG_CLONED_MAC:-}"
    if [ "$clone_val" = "--" ] || [ -z "$clone_val" ]; then
      run_priv nmcli con mod "$CONN_NAME" "$MAC_PROP" "" 2>/dev/null || true
    else
      run_priv nmcli con mod "$CONN_NAME" "$MAC_PROP" "$clone_val" 2>/dev/null || true
    fi
  else
    # Fallback if no orig file
    run_priv nmcli con mod "$CONN_NAME" ipv4.method auto 2>/dev/null || true
    run_priv nmcli con mod "$CONN_NAME" "$MAC_PROP" "" 2>/dev/null || true
  fi

  # 3. Reactivate the connection (or restart NM for maximum cleanliness)
  run_priv nmcli con up "$CONN_NAME" 2>/dev/null || true

  # Alternative more forceful reset (uncomment if needed):
  # run_priv systemctl restart NetworkManager
  # sleep 5

  whiptail --msgbox "Reset complete.\n\nMAC restored to permanent hardware address.\nNetworkManager profile restored to original settings." 10 55
  show_status
}

rolling_mode() {
  local interval_str
  interval_str=$(whiptail --inputbox \
"Rolling interval in seconds (time between each change).\n\n\
Recommended: 30-120 seconds\n\
Lower values = more frequent changes (may be noticeable to APs)\n\
Minimum: 10" \
12 62 "45" 3>&1 1>&2 2>&3) || return

  local interval=45
  if [[ "$interval_str" =~ ^[0-9]+$ ]] && [ "$interval_str" -ge 10 ]; then
    interval=$interval_str
  fi

  if ! get_sudo_pass; then return; fi
  # Refresh sudo timestamp so background work in the loop can use run_priv
  echo "$SUDO_PASS" | sudo -S --prompt="" -v 2>/dev/null || true

  clear
  cat <<'EOF'
╔════════════════════════════════════════════════════════════════╗
║           ROLLING IP & MAC CHANGER — CONTINUOUS MODE           ║
╠════════════════════════════════════════════════════════════════╣
EOF
  echo "║  Interface : $IFACE"
  echo "║  Interval  : ${interval}s between changes"
  echo "║"
  echo "║  • Random MAC + DHCP IP renew will repeat forever."
  echo "║  • Press Ctrl+C (or close the terminal) to STOP."
  echo "║  • When stopped, the last spoofed MAC/IP stay active."
  echo "║  • Use menu option 4 (Reset) later to restore originals."
  cat <<'EOF'
╚════════════════════════════════════════════════════════════════╝
EOF

  local stopped=false
  local count=0
  export ROLLING_ACTIVE=true

  trap 'stopped=true; echo -e "\n" >&2' INT TERM

  while ! $stopped; do
    count=$((count + 1))
    echo ""
    echo "[$(date +%T)] Roll #$count — applying new random MAC + IP..."
    do_random_roll

    local cur_mac cur_ip_full cur_ip
    cur_mac=$(macchanger -s "$IFACE" 2>/dev/null | awk '/Current MAC:/ {print $3}' || echo "??")
    cur_ip_full=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}' || echo "none")
    cur_ip=${cur_ip_full%%/*}

    echo "    Current MAC: $cur_mac"
    echo "    Current IP : $cur_ip"
    echo "    Next change in ${interval}s (Ctrl+C to stop now)..."

    # Interruptible sleep
    local s=0
    while [ $s -lt $interval ] && ! $stopped; do
      sleep 1
      s=$((s + 1))
    done
  done

  trap - INT TERM
  unset ROLLING_ACTIVE

  echo ""
  echo "Rolling stopped after $count change(s)."
  echo "Spoofed state from the last roll remains in effect."
  echo ""
  read -r -p "Press Enter to return to the main menu... "

  # Password remains valid for this session
  HAVE_SUDO_PASS=true
}

change_interface() {
  local list ifs choice
  # Build a simple list of non-lo interfaces
  ifs=$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {printf "%s ", $2}')

  choice=$(whiptail --title "Select Interface" --menu "Current: $IFACE\n\nPick new interface:" 16 50 6 \
    $ifs "Cancel" "Keep current" 3>&1 1>&2 2>&3) || return

  [ "$choice" = "Cancel" ] || [ "$choice" = "Keep current" ] && return

  IFACE="$choice"
  # Re-detect connection for the new iface and re-init orig (will not overwrite if exists)
  detect_connection
  whiptail --msgbox "Target interface changed to: $IFACE\nConnection: $CONN_NAME" 8 50
}

# ---------- main ----------

if ! have_cmd whiptail; then
  echo "whiptail is required (usually installed). Try: sudo apt install whiptail"
  exit 1
fi
if ! have_cmd macchanger; then
  die "macchanger is not installed.\n\nInstall with:\n  sudo apt update && sudo apt install macchanger"
fi
if ! have_cmd nmcli; then
  die "nmcli (NetworkManager) not found. This tool is designed for Kali desktop."
fi
if ! have_cmd ip; then
  die "ip command (iproute2) not found."
fi

detect_iface
init_original_config

# Friendly welcome on first run
if [ ! -f "$HOME/.config/kali-ip-mac-changer/.welcomed" ]; then
  whiptail --title "Kali IP & MAC Changer" --msgbox \
"Welcome!

This tool lets you easily spoof your IP and MAC on Kali Linux.

IMPORTANT:
- Your sudo password is NEVER stored.
- You will be prompted once per session when making changes.
- To remove all password prompts, configure sudoers (see top of script).

Interface: $IFACE
Connection: $CONN_NAME

Created for desktop launcher use." 16 65
  mkdir -p "$HOME/.config/kali-ip-mac-changer"
  touch "$HOME/.config/kali-ip-mac-changer/.welcomed"
fi

# Main menu loop
while true; do
  CHOICE=$(whiptail --title "Kali IP & MAC Changer" \
    --menu "Interface: $IFACE   |   Connection: ${CONN_NAME:-N/A}\n\nChoose an action (use arrow keys + Enter):" 20 74 10 \
    "1" "Set custom IP address (static in current subnet)" \
    "2" "Set custom MAC address" \
    "3" "Random MAC + random IP (via DHCP renew)" \
    "4" "Reset to real (original) MAC and IP config" \
    "5" "Show current IP and MAC status" \
    "6" "Change target network interface" \
    "7" "Rolling: continuously randomize MAC + IP until stopped (Ctrl+C)" \
    "8" "Exit" \
    3>&1 1>&2 2>&3)

  case "$CHOICE" in
    1) set_custom_ip ;;
    2) set_custom_mac ;;
    3) random_mac_and_ip ;;
    4) reset_to_real ;;
    5) show_status ;;
    6) change_interface ;;
    7) rolling_mode ;;
    8|"") 
       HAVE_SUDO_PASS=false
       SUDO_PASS=""
       clear
       echo "Done. Your network changes are active until reboot or reset."
       exit 0
       ;;
  esac
done
