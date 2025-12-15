#!/usr/bin/env bash
#===============================================================================
# nft_forward_manager.sh
#
# Interactive NAT port-forward manager using *native nftables*.
#
# Fixes vs prior version:
#   - Menu selection input is robust even if stdin is not a TTY (e.g. piped runs).
#   - Reads are forced from /dev/tty when available so the script won't “fall out”
#     to the caller shell after option 3.
#   - All interactive prompts use a single helper: prompt()
#   - Better comments.
#
# What it does:
#   - Saves rules in: /etc/nft_forward.conf
#   - Generates nft script: /etc/nftables.d/ifm.nft
#   - Loads via: nft -f /etc/nftables.d/ifm.nft
#   - Only manages its own nft tables: ifm_nat / ifm_nat6 / ifm_filter
#
# Rule format (one per line in /etc/nft_forward.conf):
#   v4 tcp 1200 192.168.1.2 8443
#   v6 tcp 60001 2001:db8::2 8443
#===============================================================================

set -Eeuo pipefail

CONFIG_FILE="/etc/nft_forward.conf"
NFT_FILE="/etc/nftables.d/ifm.nft"

#----------------------------- Toggles -----------------------------------------
# SNAT/MASQUERADE behavior (postrouting):
#
# ENABLE_SNAT_V4=1 (default):
#   - Adds: masquerade for traffic that is forwarded to the destination.
#   - This is common when you DNAT from a public IPv4 to a private RFC1918 host
#     (192.168/10/172.16) because it guarantees the *return traffic* comes back
#     through this box even if the destination host's routing is not perfect.
#   - Downside: the destination host sees the source as THIS gateway IP, not the
#     real client IP (you lose original source IP visibility).
#
# ENABLE_SNAT_V6=0 (default):
#   - By default we DO NOT do NAT66/masquerade for IPv6.
#   - IPv6 is designed to be routed end-to-end; usually you want the destination
#     to see the real client IPv6 address.
#   - Enable SNAT for IPv6 only if you *really* need it (special return-path/
#     asymmetric routing problems). NAT66 is generally discouraged.
ENABLE_SNAT_V4=1
ENABLE_SNAT_V6=0

#----------------------------- Our tables --------------------------------------
T4="ifm_nat"       # table ip
T6="ifm_nat6"      # table ip6
TF="ifm_filter"    # table inet

#----------------------------- Root check --------------------------------------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This script must be run as root."
  exit 1
fi

#----------------------------- Helpers -----------------------------------------
die(){ echo "Error: $*" >&2; exit 1; }

# Read user input robustly:
# - If /dev/tty exists, always read from it. This avoids the common failure mode
#   where stdin is closed/consumed (e.g. script launched by a tool, systemd,
#   heredoc, or someone accidentally piped input).
# - If no tty, fall back to stdin.
prompt() {
  local __var="$1"; shift
  local __msg="$*"
  local __ans=""

  if [[ -e /dev/tty ]]; then
    # shellcheck disable=SC2162
    read -r -p "$__msg" __ans </dev/tty || return 1
  else
    # shellcheck disable=SC2162
    read -r -p "$__msg" __ans || return 1
  fi
  printf -v "$__var" '%s' "$__ans"
}

pause() {
  local _
  prompt _ "Press Enter to continue... " || true
}

is_valid_proto(){ [[ "$1" == "tcp" || "$1" == "udp" ]]; }

# 1..65535, enforce base-10.
is_valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }

is_valid_ipv4(){
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for x in "$a" "$b" "$c" "$d"; do (( 0 <= 10#$x && 10#$x <= 255 )) || return 1; done
}

# Heuristic IPv6 check. Strict validation in bash is painful.
looks_like_ipv6(){ [[ "$1" == *:* ]]; }

check_nft_present(){ command -v nft >/dev/null 2>&1 || die "nft not found. Install nftables first."; }

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

enable_forwarding() {
  echo -e "\n[Enabling IPv4/IPv6 forwarding]"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true

  mkdir -p /etc/sysctl.d
  printf "net.ipv4.ip_forward=1\n" > /etc/sysctl.d/99-ipforward.conf
  printf "net.ipv6.conf.all.forwarding=1\n" > /etc/sysctl.d/99-ipv6forward.conf
}

init_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "# family(v4/v6) proto local_port dest_ip dest_port" > "$CONFIG_FILE"
    echo "Config created at $CONFIG_FILE"
  }
  mkdir -p "$(dirname "$NFT_FILE")"
}

rule_exists(){ grep -Fxq "$1" "$CONFIG_FILE"; }

list_rules() {
  echo -e "\nSaved rules:"
  mapfile -t RULES < <(grep -Ev '^(#|\s*$)' "$CONFIG_FILE" || true)
  for i in "${!RULES[@]}"; do echo "[$i] ${RULES[$i]}"; done
  [[ ${#RULES[@]} -eq 0 ]] && echo "<no rules>"
}

add_rule_interactive() {
  local fam proto lport dip dport
  prompt fam  "Family (v4/v6): " || return
  prompt proto "Protocol (tcp/udp): " || return
  prompt lport "Local port (1-65535): " || return
  prompt dip  "Destination IP: " || return
  prompt dport "Destination port (1-65535): " || return

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
  if rule_exists "$line"; then
    echo "Already exists: $line"
    return
  fi

  echo "$line" >> "$CONFIG_FILE"
  echo "Added (saved): $line"
}

del_rule_interactive() {
  list_rules
  mapfile -t RULES < <(grep -Ev '^(#|\s*$)' "$CONFIG_FILE" || true)
  [[ ${#RULES[@]} -eq 0 ]] && { echo "No rules to delete."; return; }

  local idx
  prompt idx "Index to delete: " || return

  if [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 0 || idx >= ${#RULES[@]} )); then
    echo "Invalid index."
    return
  fi

  {
    grep -E '^(#|\s*$)' "$CONFIG_FILE" || true
    for i in "${!RULES[@]}"; do
      (( i == idx )) && continue
      echo "${RULES[$i]}"
    done
  } > "/tmp/nft_forward.conf.$$" && mv "/tmp/nft_forward.conf.$$" "$CONFIG_FILE"

  echo "Deleted: ${RULES[$idx]}"
}

apply_rules() {
  check_nft_present
  echo -e "\n[Applying rules via nftables: $NFT_FILE]"

  # Delete ONLY our tables (safe)
  nft list table ip   "$T4" >/dev/null 2>&1 && nft delete table ip   "$T4" || true
  nft list table ip6  "$T6" >/dev/null 2>&1 && nft delete table ip6  "$T6" || true
  nft list table inet "$TF" >/dev/null 2>&1 && nft delete table inet "$TF" || true

  {
    echo "## Auto-generated by nft_forward_manager.sh"
    echo "## Edit $CONFIG_FILE then re-apply"
    echo ""

    # v4 nat
    echo "table ip $T4 {"
    echo "  chain prerouting  { type nat hook prerouting  priority dstnat; policy accept; }"
    echo "  chain postrouting { type nat hook postrouting priority srcnat; policy accept; }"
    echo "}"
    echo ""

    # v6 nat
    echo "table ip6 $T6 {"
    echo "  chain prerouting  { type nat hook prerouting  priority dstnat; policy accept; }"
    echo "  chain postrouting { type nat hook postrouting priority srcnat; policy accept; }"
    echo "}"
    echo ""

    # forward allow rules
    echo "table inet $TF {"
    echo "  chain forward { type filter hook forward priority -100; policy accept;"
    echo "    ct state established,related accept"
    echo "  }"
    echo "}"
    echo ""

    while read -r line; do
      [[ -z "${line// }" || "$line" =~ ^# ]] && continue
      local fam proto lport dip dport
      read -r fam proto lport dip dport <<<"$line" || continue
      [[ -z "${dport:-}" ]] && continue

      if [[ "$fam" == "v4" ]]; then
        echo "add rule ip   $T4 prerouting  $proto dport $lport dnat to $dip:$dport"
        if [[ "$ENABLE_SNAT_V4" == "1" ]]; then
          echo "add rule ip   $T4 postrouting ip daddr $dip $proto dport $dport masquerade"
        fi
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

  # Check syntax first, then load.
  nft -c -f "$NFT_FILE"
  nft -f "$NFT_FILE"

  echo "Done. (syntax OK and loaded)"
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

#----------------------------- Main --------------------------------------------
init_config
enable_forwarding

while true; do
  show_menu
  choice=""
  if ! prompt choice "Choose an option [1-7]: "; then
    # If input fails (EOF), exit cleanly instead of falling back to caller shell mid-flow.
    echo "\nInput closed; exiting."
    exit 0
  fi

  case "$choice" in
    1) install_nftables; enable_forwarding; pause ;;
    2) add_rule_interactive; pause ;;
    3) del_rule_interactive; pause ;;
    4) list_rules; pause ;;
    5) apply_rules; pause ;;
    6) show_runtime; pause ;;
    7) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice."; pause ;;
  esac
done
