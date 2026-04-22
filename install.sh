#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_NAME=$(basename "$0")
VERSION="0.1.0"

INTERFACE="wg0"
PORT="51820"
VPN_CIDR="10.77.0.0/24"
SERVER_ADDRESS="10.77.0.1/24"
DNS_SERVERS="1.1.1.1, 1.0.0.1"
OUTPUT_DIR="/root/wireguard-clients"
STATE_DIR="/etc/wireguard"
ENDPOINT=""
PUBLIC_IFACE=""
APPLY_CHANGES=1
INSTALL_PACKAGES=1
RESTART_SERVICE=1
GENERATE_QR=1

PEERS=()
PEER_OCTETS=()

usage() {
  cat <<'EOF'
One-command WireGuard full private VPN bootstrap for Ubuntu/Debian VPS.

Usage:
  sudo bash setup-private-vpn.sh --peer macbook --peer iphone

Options:
  --peer NAME[:OCTET]   Add a client peer. Reuse existing keys when present.
                        Example: --peer macbook --peer iphone:9
  --endpoint HOST       Public IP or DNS for client configs. Auto-detected by default.
  --public-iface IFACE  Outbound interface. Auto-detected by default.
  --interface IFACE     WireGuard interface name (default: wg0)
  --port PORT           UDP listen port (default: 51820)
  --vpn-cidr CIDR       VPN subnet CIDR (default: 10.77.0.0/24)
  --server-address CIDR Server interface address (default: 10.77.0.1/24)
  --dns CSV             Client DNS servers (default: 1.1.1.1, 1.0.0.1)
  --output-dir PATH     Where client configs and QR PNGs are written
  --state-dir PATH      WireGuard state/key directory (default: /etc/wireguard)
  --no-install          Skip apt install step
  --no-restart          Skip systemctl restart after writing config
  --no-qr               Skip QR PNG generation
  --dry-run             Render files and validations without changing systemd/network
  -h, --help            Show this help

Examples:
  sudo bash setup-private-vpn.sh --peer macbook --peer iphone
  sudo bash setup-private-vpn.sh --endpoint vpn.example.com --peer macbook --peer iphone
EOF
}

log() {
  printf '[private-vpn] %s\n' "$*"
}

die() {
  printf '[private-vpn] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

sanitize_peer_name() {
  local raw="$1"
  local safe
  safe=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')
  safe=$(printf '%s' "$safe" | sed 's/^-*//; s/-*$//')
  [[ -n "$safe" ]] || die "invalid peer name: $raw"
  printf '%s' "$safe"
}

vpn_network_base() {
  printf '%s' "$VPN_CIDR" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}'
}

validate_octet() {
  local octet="$1"
  [[ "$octet" =~ ^[0-9]+$ ]] || die "invalid peer IP octet: $octet"
  (( octet >= 2 && octet <= 254 )) || die "peer IP octet must be between 2 and 254"
}

parse_peer() {
  local raw="$1"
  local name octet
  if [[ "$raw" == *:* ]]; then
    name=${raw%%:*}
    octet=${raw##*:}
    validate_octet "$octet"
  else
    name=$raw
    octet=""
  fi
  name=$(sanitize_peer_name "$name")
  PEERS+=("$name")
  PEER_OCTETS+=("$octet")
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --peer)
        [[ $# -ge 2 ]] || die "--peer needs a value"
        parse_peer "$2"
        shift 2
        ;;
      --endpoint)
        [[ $# -ge 2 ]] || die "--endpoint needs a value"
        ENDPOINT=$(trim "$2")
        shift 2
        ;;
      --public-iface)
        [[ $# -ge 2 ]] || die "--public-iface needs a value"
        PUBLIC_IFACE=$(trim "$2")
        shift 2
        ;;
      --interface)
        [[ $# -ge 2 ]] || die "--interface needs a value"
        INTERFACE=$(trim "$2")
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port needs a value"
        PORT=$(trim "$2")
        shift 2
        ;;
      --vpn-cidr)
        [[ $# -ge 2 ]] || die "--vpn-cidr needs a value"
        VPN_CIDR=$(trim "$2")
        shift 2
        ;;
      --server-address)
        [[ $# -ge 2 ]] || die "--server-address needs a value"
        SERVER_ADDRESS=$(trim "$2")
        shift 2
        ;;
      --dns)
        [[ $# -ge 2 ]] || die "--dns needs a value"
        DNS_SERVERS=$(trim "$2")
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "--output-dir needs a value"
        OUTPUT_DIR=$(trim "$2")
        shift 2
        ;;
      --state-dir)
        [[ $# -ge 2 ]] || die "--state-dir needs a value"
        STATE_DIR=$(trim "$2")
        shift 2
        ;;
      --no-install)
        INSTALL_PACKAGES=0
        shift
        ;;
      --no-restart)
        RESTART_SERVICE=0
        shift
        ;;
      --no-qr)
        GENERATE_QR=0
        shift
        ;;
      --dry-run)
        APPLY_CHANGES=0
        INSTALL_PACKAGES=0
        RESTART_SERVICE=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  (( ${#PEERS[@]} > 0 )) || die "add at least one --peer"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "port must be numeric"
  (( PORT >= 1 && PORT <= 65535 )) || die "port must be 1-65535"
}

detect_public_iface() {
  ip route get 1.1.1.1 | awk '/dev/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

detect_endpoint() {
  local iface="$1"
  ip -4 addr show "$iface" scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
}

install_deps() {
  (( INSTALL_PACKAGES == 1 )) || return 0
  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard wireguard-tools qrencode iptables
  else
    die "unsupported package manager, install wireguard tools manually"
  fi
}

check_runtime_tools() {
  local required=(wg ip iptables install mktemp awk sed grep cut seq ss)
  local tool
  for tool in "${required[@]}"; do
    have_cmd "$tool" || die "required command missing: $tool"
  done
  if (( RESTART_SERVICE == 1 )); then
    have_cmd systemctl || die "required command missing: systemctl"
  fi
}

ensure_sysctl() {
  if (( APPLY_CHANGES == 0 )); then
    log "dry-run: skipping sysctl changes"
    return 0
  fi
  mkdir -p /etc/sysctl.d
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wireguard-private-vpn.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

ensure_dirs() {
  mkdir -p "$STATE_DIR/peers" "$OUTPUT_DIR"
  chmod 700 "$STATE_DIR" "$STATE_DIR/peers" "$OUTPUT_DIR"
}

ensure_keypair() {
  local private_key_path="$1"
  local public_key_path="$2"
  if [[ ! -f "$private_key_path" || ! -f "$public_key_path" ]]; then
    wg genkey | tee "$private_key_path" | wg pubkey > "$public_key_path"
    chmod 600 "$private_key_path" "$public_key_path"
  fi
}

ensure_psk() {
  local psk_path="$1"
  if [[ ! -f "$psk_path" ]]; then
    wg genpsk > "$psk_path"
    chmod 600 "$psk_path"
  fi
}

next_auto_octet() {
  local used="$1"
  local octet
  for octet in $(seq 2 254); do
    if ! grep -qx "$octet" <<<"$used"; then
      printf '%s' "$octet"
      return 0
    fi
  done
  return 1
}

prepare_peers() {
  local net_base="$1"
  local used_octets="1"
  local idx requested_octet name peer_dir priv pub psk peer_ip endpoint

  for requested_octet in "${PEER_OCTETS[@]}"; do
    [[ -n "$requested_octet" ]] && used_octets+=$'\n'"$requested_octet"
  done

  SERVER_PRIVATE_KEY_PATH="${STATE_DIR}/${INTERFACE}_server_private.key"
  SERVER_PUBLIC_KEY_PATH="${STATE_DIR}/${INTERFACE}_server_public.key"
  ensure_keypair "$SERVER_PRIVATE_KEY_PATH" "$SERVER_PUBLIC_KEY_PATH"
  SERVER_PUBLIC_KEY=$(<"$SERVER_PUBLIC_KEY_PATH")
  SERVER_PRIVATE_KEY=$(<"$SERVER_PRIVATE_KEY_PATH")

  PEER_BLOCKS=()
  PEER_SUMMARY=()

  for idx in "${!PEERS[@]}"; do
    name=${PEERS[$idx]}
    requested_octet=${PEER_OCTETS[$idx]}
    if [[ -z "$requested_octet" ]]; then
      requested_octet=$(next_auto_octet "$used_octets") || die "no free peer octets left"
      used_octets+=$'\n'"$requested_octet"
      PEER_OCTETS[$idx]="$requested_octet"
    fi

    peer_dir="${STATE_DIR}/peers/$name"
    mkdir -p "$peer_dir"
    chmod 700 "$peer_dir"
    priv="$peer_dir/private.key"
    pub="$peer_dir/public.key"
    psk="$peer_dir/preshared.key"
    ensure_keypair "$priv" "$pub"
    ensure_psk "$psk"
    peer_ip="$net_base.$requested_octet/32"

    local peer_public peer_psk peer_private client_conf client_qr_png client_qr_txt
    peer_public=$(<"$pub")
    peer_psk=$(<"$psk")
    peer_private=$(<"$priv")

    PEER_BLOCKS+=("[Peer]
PublicKey = ${peer_public}
PresharedKey = ${peer_psk}
AllowedIPs = ${peer_ip}")

    client_conf="$OUTPUT_DIR/${name}.conf"
    cat > "$client_conf" <<EOF
[Interface]
PrivateKey = ${peer_private}
Address = ${peer_ip}
DNS = ${DNS_SERVERS}
MTU = 1380

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${peer_psk}
Endpoint = ${ENDPOINT}:${PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$client_conf"

    if (( GENERATE_QR == 1 )) && have_cmd qrencode; then
      client_qr_png="$OUTPUT_DIR/${name}.png"
      client_qr_txt="$OUTPUT_DIR/${name}.txt"
      qrencode -o "$client_qr_png" -s 8 -l H < "$client_conf"
      qrencode -t ansiutf8 < "$client_conf" > "$client_qr_txt"
      chmod 600 "$client_qr_png" "$client_qr_txt"
    fi

    PEER_SUMMARY+=("${name}:${peer_ip}:${client_conf}")
  done
}

render_wg_conf() {
  local target="$1"
  {
    cat <<EOF
[Interface]
Address = ${SERVER_ADDRESS}
ListenPort = ${PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -o ${PUBLIC_IFACE} -s ${VPN_CIDR} -j ACCEPT; iptables -A FORWARD -i ${PUBLIC_IFACE} -o %i -m conntrack --ctstate ESTABLISHED,RELATED -d ${VPN_CIDR} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${PUBLIC_IFACE} -s ${VPN_CIDR} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o ${PUBLIC_IFACE} -s ${VPN_CIDR} -j ACCEPT; iptables -D FORWARD -i ${PUBLIC_IFACE} -o %i -m conntrack --ctstate ESTABLISHED,RELATED -d ${VPN_CIDR} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${PUBLIC_IFACE} -s ${VPN_CIDR} -j MASQUERADE
EOF
    printf '\n'
    printf '%s\n\n' "${PEER_BLOCKS[@]}"
  } > "$target"
}

purge_rule() {
  local table="$1"
  shift
  if [[ -n "$table" ]]; then
    while iptables -t "$table" -C "$@" 2>/dev/null; do
      iptables -t "$table" -D "$@" || true
    done
  else
    while iptables -C "$@" 2>/dev/null; do
      iptables -D "$@" || true
    done
  fi
}

cleanup_full_tunnel_rules() {
  purge_rule "" FORWARD -i "$INTERFACE" -o "$PUBLIC_IFACE" -s "$VPN_CIDR" -j ACCEPT
  purge_rule "" FORWARD -i "$PUBLIC_IFACE" -o "$INTERFACE" -m conntrack --ctstate ESTABLISHED,RELATED -d "$VPN_CIDR" -j ACCEPT
  purge_rule "nat" POSTROUTING -o "$PUBLIC_IFACE" -s "$VPN_CIDR" -j MASQUERADE
}

apply_wg_conf() {
  local target_conf="${STATE_DIR}/${INTERFACE}.conf"
  local tmp_conf
  tmp_conf=$(mktemp)
  render_wg_conf "$tmp_conf"

  if (( APPLY_CHANGES == 0 )); then
    install -m 600 "$tmp_conf" "${OUTPUT_DIR}/${INTERFACE}.server.conf"
    rm -f "$tmp_conf"
    log "dry-run: rendered server config to ${OUTPUT_DIR}/${INTERFACE}.server.conf"
    return 0
  fi

  install -m 600 "$tmp_conf" "$target_conf"
  rm -f "$tmp_conf"

  if (( RESTART_SERVICE == 1 )); then
    cleanup_full_tunnel_rules
    systemctl enable "wg-quick@${INTERFACE}" >/dev/null
    systemctl restart "wg-quick@${INTERFACE}"
  fi
}

validate_server() {
  if (( RESTART_SERVICE == 1 )); then
    systemctl is-active --quiet "wg-quick@${INTERFACE}" || die "wg-quick@${INTERFACE} is not active"
    ss -lunp | grep -q ":${PORT} " || die "UDP ${PORT} not listening"
    log "WireGuard service is active and listening on UDP ${PORT}"
  else
    log "Dry-run or no-restart mode, skipped live service validation"
  fi

  log "Client configs written to ${OUTPUT_DIR}"
  local item name ip conf_path
  for item in "${PEER_SUMMARY[@]}"; do
    IFS=':' read -r name ip conf_path <<<"$item"
    log "peer=${name} ip=${ip} config=${conf_path}"
  done
}

main() {
  require_root
  parse_args "$@"
  if (( APPLY_CHANGES == 0 )) && [[ "$STATE_DIR" == "/etc/wireguard" ]]; then
    STATE_DIR=$(mktemp -d /tmp/private-vpn-bootstrap-state.XXXXXX)
    log "dry-run: using temporary state dir ${STATE_DIR}"
  fi
  install_deps
  check_runtime_tools
  ensure_sysctl
  ensure_dirs

  [[ -n "$PUBLIC_IFACE" ]] || PUBLIC_IFACE=$(detect_public_iface)
  [[ -n "$PUBLIC_IFACE" ]] || die "failed to detect public interface"
  [[ -n "$ENDPOINT" ]] || ENDPOINT=$(detect_endpoint "$PUBLIC_IFACE")
  [[ -n "$ENDPOINT" ]] || die "failed to detect endpoint, pass --endpoint manually"

  local net_base
  net_base=$(vpn_network_base)
  [[ -n "$net_base" ]] || die "failed to derive VPN network base from ${VPN_CIDR}"

  prepare_peers "$net_base"
  apply_wg_conf
  validate_server

  log "done"
  log "one-liner next time: sudo bash ${SCRIPT_NAME} $(printf -- '--peer %q ' "${PEERS[@]}")"
}

main "$@"
