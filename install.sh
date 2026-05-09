#!/usr/bin/env bash
set -euo pipefail

# Full WireGuard installer for this script bundle.
# Run from vpsfiles/wireguard-scripts, then add clients with ./add-client.sh.

WG_IF_DEFAULT="wg0"
WG_PORT_DEFAULT="51820"
WG_NET_DEFAULT="10.8.0.0/24"
WG_SERVER_IP_DEFAULT="10.8.0.1"
WG_DIR="/etc/wireguard"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_TEMPLATE="${SCRIPT_DIR}/wg0-server.example.conf"
CLIENT_TEMPLATE="${SCRIPT_DIR}/wg0-client.example.conf"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
LAST_IP_FILE="${SCRIPT_DIR}/last-ip.txt"
ENDPOINT_FILE="${SCRIPT_DIR}/server-endpoint.txt"

WG_IF="${WG_IF:-${WG_IF_DEFAULT}}"
WG_PORT="${WG_PORT:-${WG_PORT_DEFAULT}}"
WG_NET="${WG_NET:-${WG_NET_DEFAULT}}"
WG_SERVER_IP="${WG_SERVER_IP:-${WG_SERVER_IP_DEFAULT}}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
SERVER_IF="${SERVER_IF:-}"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"
WG_PREFIX="24"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root:"
    echo "  sudo bash ${0}"
    exit 1
  fi
}

require_files() {
  local missing=0

  for file in \
    "${SERVER_TEMPLATE}" \
    "${CLIENT_TEMPLATE}" \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/add-peer.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/remove-peer.sh" \
    "${SCRIPT_DIR}/uninstall.sh"; do
    if [[ ! -f "${file}" ]]; then
      echo "ERROR: required file is missing: ${file}"
      missing=1
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

require_supported_os() {
  if ! command -v apt >/dev/null 2>&1; then
    echo "ERROR: this installer currently supports Debian/Ubuntu systems with apt."
    exit 1
  fi
}

prompt() {
  local name="$1"
  local label="$2"
  local default="$3"
  local value=""

  read -r -p "${label} [${default}]: " value
  printf -v "${name}" '%s' "${value:-${default}}"
}

confirm() {
  local message="$1"
  local answer=""

  read -r -p "${message} [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

detect_server_if() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

detect_public_ip() {
  local ip_addr=""

  if command -v curl >/dev/null 2>&1; then
    ip_addr="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${ip_addr}" ]]; then
      ip_addr="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    fi
  fi

  echo "${ip_addr}"
}

install_packages() {
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y \
    curl \
    iproute2 \
    iptables \
    qrencode \
    ufw \
    wireguard \
    wireguard-tools
}

backup_existing_configs() {
  local timestamp=""
  local backup_dir=""
  local found=0

  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${BACKUP_ROOT}/${timestamp}"

  for path in \
    "${WG_DIR}/${WG_IF}.conf" \
    "${WG_DIR}/server_private_key" \
    "${WG_DIR}/server_public_key" \
    "${LAST_IP_FILE}" \
    "${ENDPOINT_FILE}" \
    "${SCRIPT_DIR}/server-port.txt" \
    "${SCRIPT_DIR}/server-interface.txt" \
    "${SCRIPT_DIR}/server-net.txt"; do
    if [[ -e "${path}" ]]; then
      found=1
      break
    fi
  done
  if [[ -d "${CLIENTS_DIR}" ]] && find "${CLIENTS_DIR}" -mindepth 1 -maxdepth 1 | read -r; then
    found=1
  fi

  if [[ "${found}" -eq 0 ]]; then
    return 0
  fi

  echo
  echo "Existing WireGuard/script config was found."
  echo "Backup destination: ${backup_dir}"
  if ! confirm "Back up existing config before continuing?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  mkdir -p "${backup_dir}/etc-wireguard" "${backup_dir}/script-files"

  if [[ -e "${WG_DIR}/${WG_IF}.conf" ]]; then
    cp -a "${WG_DIR}/${WG_IF}.conf" "${backup_dir}/etc-wireguard/"
  fi
  if [[ -e "${WG_DIR}/server_private_key" ]]; then
    cp -a "${WG_DIR}/server_private_key" "${backup_dir}/etc-wireguard/"
  fi
  if [[ -e "${WG_DIR}/server_public_key" ]]; then
    cp -a "${WG_DIR}/server_public_key" "${backup_dir}/etc-wireguard/"
  fi
  if [[ -e "${LAST_IP_FILE}" ]]; then
    cp -a "${LAST_IP_FILE}" "${backup_dir}/script-files/"
  fi
  if [[ -e "${ENDPOINT_FILE}" ]]; then
    cp -a "${ENDPOINT_FILE}" "${backup_dir}/script-files/"
  fi
  if [[ -e "${SCRIPT_DIR}/server-port.txt" ]]; then
    cp -a "${SCRIPT_DIR}/server-port.txt" "${backup_dir}/script-files/"
  fi
  if [[ -e "${SCRIPT_DIR}/server-interface.txt" ]]; then
    cp -a "${SCRIPT_DIR}/server-interface.txt" "${backup_dir}/script-files/"
  fi
  if [[ -e "${SCRIPT_DIR}/server-net.txt" ]]; then
    cp -a "${SCRIPT_DIR}/server-net.txt" "${backup_dir}/script-files/"
  fi
  if [[ -d "${CLIENTS_DIR}" ]]; then
    cp -a "${CLIENTS_DIR}" "${backup_dir}/script-files/"
  fi

  echo "Backup complete: ${backup_dir}"
}

stop_existing_wireguard() {
  if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "Stopping active wg-quick@${WG_IF} before replacing config..."
    systemctl stop "wg-quick@${WG_IF}"
  fi
}

enable_ip_forwarding() {
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wireguard.conf
  sysctl --system >/dev/null
}

generate_server_keys() {
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"

  umask 077
  wg genkey | tee "${WG_DIR}/server_private_key" | wg pubkey > "${WG_DIR}/server_public_key"
  chmod 600 "${WG_DIR}/server_private_key" "${WG_DIR}/server_public_key"
}

render_server_config() {
  local server_private_key=""

  server_private_key="$(cat "${WG_DIR}/server_private_key")"
  if [[ "${WG_NET}" == */* ]]; then
    WG_PREFIX="${WG_NET##*/}"
  fi

  sed \
    -e "s|:SERVER_PRIV_KEY:|${server_private_key}|g" \
    -e "s|:SERVER_IP:|${WG_SERVER_IP}|g" \
    -e "s|:SERVER_PREFIX:|${WG_PREFIX}|g" \
    -e "s|:SERVER_PORT:|${WG_PORT}|g" \
    -e "s|:SERVER_NET:|${WG_NET}|g" \
    -e "s|:SERVER_IF:|${SERVER_IF}|g" \
    "${SERVER_TEMPLATE}" > "${WG_DIR}/${WG_IF}.conf"

  chmod 600 "${WG_DIR}/${WG_IF}.conf"
}

prepare_script_state() {
  mkdir -p "${CLIENTS_DIR}"

  printf '%s\n' "${WG_SERVER_IP}" > "${LAST_IP_FILE}"
  printf '%s\n' "${WG_ENDPOINT}" > "${ENDPOINT_FILE}"
  printf '%s\n' "${WG_PORT}" > "${SCRIPT_DIR}/server-port.txt"
  printf '%s\n' "${WG_IF}" > "${SCRIPT_DIR}/server-interface.txt"
  printf '%s\n' "${WG_NET}" > "${SCRIPT_DIR}/server-net.txt"

  chmod +x \
    "${SCRIPT_DIR}/add-client.sh" \
    "${SCRIPT_DIR}/add-peer.sh" \
    "${SCRIPT_DIR}/remove-client.sh" \
    "${SCRIPT_DIR}/remove-peer.sh" \
    "${SCRIPT_DIR}/uninstall.sh" 2>/dev/null || true
}

setup_firewall() {
  ufw allow "${WG_PORT}/udp" >/dev/null || true

  if ! ufw status | grep -q "Status: active"; then
    if confirm "UFW is not active. Enable it now?"; then
      ufw --force enable >/dev/null
    else
      echo "Skipped enabling UFW. The WireGuard UDP port was still added to UFW rules."
    fi
  fi
}

start_wireguard() {
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  systemctl restart "wg-quick@${WG_IF}"
}

collect_settings() {
  local detected_if=""
  local detected_endpoint=""

  detected_if="$(detect_server_if)"
  detected_endpoint="$(detect_public_ip)"

  prompt WG_IF "WireGuard interface name" "${WG_IF}"
  prompt WG_PORT "WireGuard UDP port" "${WG_PORT}"
  prompt WG_NET "WireGuard VPN subnet" "${WG_NET}"
  prompt WG_SERVER_IP "WireGuard server VPN IP" "${WG_SERVER_IP}"
  prompt SERVER_IF "Public network interface for NAT" "${SERVER_IF:-${detected_if:-eth0}}"
  prompt WG_ENDPOINT "Public endpoint clients should connect to" "${WG_ENDPOINT:-${detected_endpoint:-$(hostname -f)}}"
}

print_summary() {
  echo
  echo "============================================================"
  echo "WireGuard installation complete."
  echo "============================================================"
  echo
  echo "Server config:     ${WG_DIR}/${WG_IF}.conf"
  echo "Server VPN IP:     ${WG_SERVER_IP}"
  echo "VPN subnet:        ${WG_NET}"
  echo "UDP port:          ${WG_PORT}"
  echo "Public interface:  ${SERVER_IF}"
  echo "Client endpoint:   ${WG_ENDPOINT}"
  echo
  echo "Add clients with:"
  echo "  cd ${SCRIPT_DIR}"
  echo "  sudo ./add-client.sh phone      # create and add client"
  echo "  sudo ./add-peer.sh phone        # add an existing client to wg0.conf"
  echo "  sudo ./add-peer.sh --tmp phone  # add an existing client to live wg0 only"
  echo "  sudo ./remove-client.sh phone   # remove peer and client files"
  echo "  sudo ./remove-peer.sh phone     # remove an existing client from wg0.conf"
  echo "  sudo ./remove-peer.sh --tmp phone # remove an existing client from live wg0 only"
  echo "  sudo ./uninstall.sh             # remove script-created WireGuard data"
  echo
  echo "Check status with:"
  echo "  sudo wg"
  echo "  sudo systemctl status wg-quick@${WG_IF}"
}

main() {
  require_root
  require_files
  require_supported_os

  echo "WireGuard full installation"
  echo
  collect_settings

  echo
  echo "This will install packages, back up existing config if present,"
  echo "write ${WG_DIR}/${WG_IF}.conf, enable IPv4 forwarding, configure UFW,"
  echo "and start wg-quick@${WG_IF}."
  if ! confirm "Continue?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  backup_existing_configs
  install_packages
  stop_existing_wireguard
  enable_ip_forwarding
  generate_server_keys
  render_server_config
  prepare_script_state
  setup_firewall
  start_wireguard
  print_summary
}

main "$@"
