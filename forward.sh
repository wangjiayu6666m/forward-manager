#!/usr/bin/env bash
#===============================================================================
# nft_forward_manager.sh
#
# A safer interactive NAT port-forward manager using *native nftables*.
#
# What it does:
#   - Stores rules in a config file: /etc/nft_forward.conf
#   - Generates a dedicated nft script: /etc/nftables.d/ifm.nft
#   - Loads it via: nft -f /etc/nftables.d/ifm.nft
#
# Safety goals:
#   - Only manages its own nft tables (ifm_nat / ifm_nat6 / ifm_filter)
#   - Does NOT flush or modify other system tables (docker/k8s/firewalld safer)
#
# Notes:
#   - IPv4: DNAT + (optional) masquerade SNAT
#   - IPv6: DNAT; SNAT usually not needed (optional, default off)
#   - Forwarding: adds allow rules for NEW + always allows ESTABLISHED/RELATED
#===============================================================================

set -Eeuo pipefail

#----------------------------- Files -------------------------------------------
CONFIG_FILE="/etc/nft_forward.conf"       # persistent rule storage
NFT_FILE="/etc/nftables.d/ifm.nft"        # generated nft script

#----------------------------- Toggles -----------------------------------------
# IPv4 SNAT (masquerade) is common when forwarding to private LAN behind this host.
ENABLE_SNAT_V4=1

# IPv6 SNAT usually should be OFF (IPv6 is designed to be routed end-to-end).
ENABLE_SNAT_V6=0

#----------------------------- Names (only ours) --------------------------------
# We create and delete ONLY these tables. Do not reuse their names elsewhere.
T4="ifm_nat"        # table ip
T6="ifm_nat6"       # table ip6
TF="ifm_filter"     # table inet (forward allow rules)

#----------------------------- Root check ---------------------------------------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

die(){ echo "Error: $*" >&2; exit 1; }

#----------------------------- Validators ---------------------------------------
is_valid_proto(){ [[ "$1" == "tcp" || "$1" == "udp" ]]; }

# 1..65535, avoid octal interpretation by using base-10 (10#)
is_valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }

is_valid_ipv4(){
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for x in "$a" "$b" "$c" "$d"; do (( 0 <= 10#$x && 10#$x <= 255 )) || return 1; done
}

# IPv6: strict validation is hard in pure bash; we use a lightweight heuristic.
looks_like_ipv6(){ [[ "$1" == *:* ]]; }

#----------------------------- Package install ----------------------------------
detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
  elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
  else die "No supported package manager found (apt-get/yum)."
  fi
}

install_nftables() {
  detect_pkg_mgr
  echo -e "\n[Installing nftables via $PKG_MGR]"
  if [[ $PKG_MGR == "apt-get" ]]; then
    apt-get update -y
    apt-get install -y nftables
  else
    yum makecache -y
    yum install -y nftables
  fi
  echo "Done."
}

check_nft_present() {
  command -v nft >/dev/null 2>&1 || die "nft command not found. Install nftables first (menu option 1)."
}

#----------------------------- Sysctl forwarding --------------------------------
enable_forwarding() {
  echo -e "\n[Enabling IPv4/IPv6 forwarding]"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  # Some minimal systems may not have ipv6 enabled; ignore failure.
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true

  mkdir -p /etc/sysctl.d
  printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-ipforward.conf
  printf "net.ipv6.conf.all.forwarding=1\n" > /etc/sysctl.d/99-ipv6forward.conf
}

#----------------------------- Config init --------------------------------------
init_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "# family(v4/v6) proto local_port dest_ip dest_port" > "$CONFIG_FILE"
    echo "Config created at $CONFIG_FILE"
  }
  mkdir -p "$(dirname "$NFT_FILE")"
}

rule_exists(){ grep -Fxq "$1" "$CONFIG_FILE"; }

#----------------------------- UI: list/add/del ---------------------------------
list_rules() {
  echo -e "\nSaved rules:"
  mapfile -t RULES < <(grep -Ev '^(#|\s*$)' "$CONFIG_FILE" || true)
  for i in "${!RULES[@]}"; do echo "[$i] ${RULES[$i]}"; done
  [[ ${#RULES[@]} -eq 0 ]] && echo "<no rules>"
}

add_rule_interactive() {
  local fam proto lport dip dport
  read -rp "Family (v4/v6): " fam
  read -rp "Protocol (tcp/udp): " proto
  read -rp "Local port (1-65535): " lport
  read -rp "Destination IP: " dip
  read -rp "Destination port (1-65535): " dport

  [[ "$fam" == "v4" || "$fam" == "v6" ]] || { echo "Invalid family."; return; }
  is_valid_proto "$proto" || { echo "Invalid proto."; return; }
  is_valid_port "$lport"  || { echo "Invalid local port."; return; }
  is_valid_port "$dport"  || { echo "Invalid destination port."; return; }

  if [[ "$fam" == "v4" ]]; then
    is_valid_ipv4 "$dip" || { echo "Invalid IPv4."; return; }
  else
    looks_like_ipv6 "$dip" || { echo "This doesn't look like IPv6."; return; }
  fi

  local line="$fam $proto $lport $dip $dport"
  rule_exists "$line" && { echo "Already exists: $line"; return; }

  echo "$line" >> "$CONFIG_FILE"
  echo "Added (saved): $line"
}

del_rule_interactive() {
  list_rules
  mapfile -t RULES < <(grep -Ev '^(#|\s*$)' "$CONFIG_FILE" || true)
  [[ ${#RULES[@]} -eq 0 ]] && { echo "No rules to delete."; return; }

  local idx
  read -rp "Index to delete: " idx
  if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 0 || idx >= ${#RULES[@]} )); then
    echo "Invalid index."
    return
  fi

  # Rewrite config file without the selected rule
  {
    grep -E '^(#|\s*$)' "$CONFIG_FILE" || true
    for i in "${!RULES[@]}"; do
      (( i == idx )) && continue
      echo "${RULES[$i]}"
    done
  } > /tmp/nft_forward.conf.$$ && mv /tmp/nft_forward.conf.$$ "$CONFIG_FILE"

  echo "Deleted: ${RULES[$idx]}"
}

#----------------------------- Apply: generate nft file --------------------------
apply_rules() {
  check_nft_present
  echo -e "\n[Applying rules via nftables: $NFT_FILE]"

  # Delete ONLY our tables if they exist (safe; does not touch other rulesets).
  nft list table ip   "$T4" >/dev/null 2>&1 && nft delete table ip   "$T4" || true
  nft list table ip6  "$T6" >/dev/null 2>&1 && nft delete table ip6  "$T6" || true
  nft list table inet "$TF" >/dev/null 2>&1 && nft delete table inet "$TF" || true

  # Generate nft script
  {
    echo "## Auto-generated by nft_forward_manager.sh"
    echo "## Do not edit by hand; edit $CONFIG_FILE then re-apply."
    echo ""

    # IPv4 NAT table (DNAT/SNAT)
    echo "table ip $T4 {"
    echo "  chain prerouting  { type nat hook prerouting  priority dstnat; policy accept; }"
    echo "  chain postrouting { type nat hook postrouting priority srcnat; policy accept; }"
    echo "}"
    echo ""

    # IPv6 NAT table (DNAT/SNAT)
    # NOTE: Some kernels/distros may not support IPv6 NAT; if loading fails, disable v6 NAT
    # or ensure required modules/features are present.
    echo "table ip6 $T6 {"
    echo "  chain prerouting  { type nat hook prerouting  priority dstnat; policy accept; }"
    echo "  chain postrouting { type nat hook postrouting priority srcnat; policy accept; }"
    echo "}"
    echo ""

    # Forward allow rules table.
    # IMPORTANT: If you already have a firewall (firewalld/ufw/custom) that drops forwarding,
    # this chain may or may not override it depending on hook priorities and other base chains.
    # - priority -100 means "earlier than default filter(0)".
    # - If another chain drops earlier than ours, ours won't help.
    # - If another chain drops later, it can still drop after we accept (multi base-chain setups).
    echo "table inet $TF {"
    echo "  chain forward { type filter hook forward priority -100; policy accept;"
    echo "    ct state established,related accept"
    echo "  }"
    echo "}"
    echo ""

    # Emit per-rule "add rule ..." commands
    while read -r line; do
      [[ -z "${line// }" || "$line" =~ ^# ]] && continue

      # Expect 5 fields: fam proto lport dip dport
      local fam proto lport dip dport
      read -r fam proto lport dip dport <<<"$line" || continue
      [[ -z "${dport:-}" ]] && continue

      if [[ "$fam" == "v4" ]]; then
        # DNAT: public(local) port -> destination ip:port
        echo "add rule ip   $T4 prerouting  $proto dport $lport dnat to $dip:$dport"
        # Optional SNAT (masquerade)
        if [[ "$ENABLE_SNAT_V4" == "1" ]]; then
          echo "add rule ip   $T4 postrouting ip daddr $dip $proto dport $dport masquerade"
        fi
        # Allow NEW forwarding to destination
        echo "add rule inet $TF forward ip daddr $dip $proto dport $dport ct state new accept"
      else
        echo "add rule ip6  $T6 prerouting  $proto dport $lport dnat to $dip:$dport"
        if [[ "$ENABLE_SNAT_V6" == "1" ]]; then
          echo "add rule ip6  $T6 postrouting ip6 daddr $dip $proto dport $dport masquerade"
        fi
        echo "add rule inet $TF forward ip6 daddr $dip $proto dport $dport ct state new accept"
      fi
    done < "$CONFIG_FILE"

  } > "$NFT_FILE"

  # 1) Syntax check first (-c means "check only")
  nft -c -f "$NFT_FILE"

  # 2) If check passes, load it
  nft -f "$NFT_FILE"

  echo "Done. (syntax check passed and loaded)"
}

show_runtime() {
  check_nft_present
  echo -e "\n[Runtime check: our tables]"
  nft list table ip   "$T4"  2>/dev/null || echo "<no table ip $T4>"
  nft list table ip6  "$T6"  2>/dev/null || echo "<no table ip6 $T6>"
  nft list table inet "$TF"  2>/dev/null || echo "<no table inet $TF>"
}

show_menu() {
  cat <<-EOF

  ====== nftables Forward Manager (v4/v6) ======
  1) Install nftables & enable forwarding
  2) Add forwarding rule (saved only)
  3) Delete forwarding rule (saved only)
  4) List saved rules
  5) Apply saved rules (generate + nft -c/-f)
  6) Show runtime rules (our tables)
  7) Exit
  =============================================
EOF
}

#----------------------------- Main ---------------------------------------------
init_config
enable_forwarding

while true; do
  show_menu
  read -rp "Choose an option [1-7]: " choice
  case "$choice" in
    1) install_nftables; enable_forwarding ;;
    2) add_rule_interactive ;;
    3) del_rule_interactive ;;
    4) list_rules ;;
    5) apply_rules ;;
    6) show_runtime ;;
    7) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
done
