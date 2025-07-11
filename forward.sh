#!/usr/bin/env bash
#===============================================================================
# iptables_forward_manager.sh
# Interactive NAT port-forwarding manager using iptables.
# Supports install/update, enable forwarding, add/list/delete/apply rules.
#===============================================================================

CONFIG_FILE="/etc/iptables_forward.conf"  # rules storage

# Ensure root privileges
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root.";
  exit 1
fi

# Detect package manager (apt-get or yum)
detect_pkg_mgr() {
  if command -v apt-get >/dev/null; then
    PKG_MGR="apt-get"
  elif command -v yum >/dev/null; then
    PKG_MGR="yum"
  else
    echo "Error: No supported package manager found." >&2
    exit 1
  fi
}

# Install or update iptables
install_or_update_iptables() {
  detect_pkg_mgr
  echo -e "\n[Installing/updating iptables via $PKG_MGR]"
  if [[ $PKG_MGR == "apt-get" ]]; then
    apt-get update -y && apt-get install -y iptables
  else
    yum makecache fast && yum install -y iptables iptables-services
  fi
  echo "Done."
}

# Enable IPv4 forwarding (temporary + persistent)
enable_ip_forwarding() {
  echo -e "\n[Enabling IPv4 forwarding]"
  sysctl -w net.ipv4.ip_forward=1
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || 
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
}

# Create config file if missing
init_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "# saved rules" > "$CONFIG_FILE"
    echo "Config created at $CONFIG_FILE"
  }
}

# Add single iptables rule
add_iptables_rule() {
  local proto=$1 lport=$2 dip=$3 dport=$4
  iptables -t nat -A PREROUTING -p "$proto" --dport "$lport" \
    -j DNAT --to-destination "$dip:$dport"
  iptables -t nat -A POSTROUTING -p "$proto" -d "$dip" --dport "$dport" \
    -j MASQUERADE
}

# Delete single iptables rule
del_iptables_rule() {
  local proto=$1 lport=$2 dip=$3 dport=$4
  iptables -t nat -D PREROUTING -p "$proto" --dport "$lport" \
    -j DNAT --to-destination "$dip:$dport" 2>/dev/null
  iptables -t nat -D POSTROUTING -p "$proto" -d "$dip" --dport "$dport" \
    -j MASQUERADE 2>/dev/null
}

# Interactive add: prompt and store
add_rule_interactive() {
  read -p "Protocol (tcp/udp): " proto
  read -p "Local port: " lport
  read -p "Destination IP: " dip
  read -p "Destination port: " dport
  echo "$proto $lport $dip $dport" >> "$CONFIG_FILE"
  add_iptables_rule "$proto" "$lport" "$dip" "$dport"
  echo "Added: $proto $lport -> $dip:$dport"
}

# List saved rules with index
list_rules() {
  echo -e "\nSaved rules:"
  mapfile -t RULES < <(grep -Ev '^(#|\s*$)' "$CONFIG_FILE")
  for i in "${!RULES[@]}"; do
    echo "[$i] ${RULES[$i]}"
  done
  [[ ${#RULES[@]} -eq 0 ]] && echo "<no rules>"
}

# Interactive delete: choose by index
del_rule_interactive() {
  list_rules
  mapfile -t RULES < <(grep -Ev '^(#|\s*$)' "$CONFIG_FILE")
  [[ ${#RULES[@]} -eq 0 ]] && { echo "No rules to delete."; return; }
  read -p "Index to delete: " idx
  if [[ ! $idx =~ ^[0-9]+$ ]] || (( idx<0 || idx>=${#RULES[@]} )); then
    echo "Invalid index."; return
  fi
  local line="${RULES[$idx]}"
  grep -vFx "$line" "$CONFIG_FILE" > /tmp/rules.tmp && mv /tmp/rules.tmp "$CONFIG_FILE"
  read proto lport dip dport <<< "$line"
  del_iptables_rule "$proto" "$lport" "$dip" "$dport"
  echo "Deleted: $line"
}

# Apply all saved rules to iptables
apply_saved_rules() {
  echo -e "\nApplying saved rules..."
  iptables -t nat -F PREROUTING
  iptables -t nat -F POSTROUTING
  while read -r line; do
    [[ -z $line || $line =~ ^# ]] && continue
    read proto lport dip dport <<< "$line"
    add_iptables_rule "$proto" "$lport" "$dip" "$dport"
  done < "$CONFIG_FILE"
  echo "Done."
}

# Display menu
show_menu() {
  cat <<-EOF

  ====== iptables Forward Manager ======
  1) Install/Update iptables & enable forwarding
  2) Add forwarding rule
  3) Delete forwarding rule
  4) List rules
  5) Apply saved rules
  6) Exit
  ======================================
EOF
}

# Main loop: init, enable forwarding, then menu
init_config
enable_ip_forwarding
while true; do
  show_menu
  read -p "Choose an option [1-6]: " choice
  case $choice in
    1) install_or_update_iptables ;;
    2) add_rule_interactive ;;
    3) del_rule_interactive ;;
    4) list_rules ;;
    5) apply_saved_rules ;;
    6) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
done
