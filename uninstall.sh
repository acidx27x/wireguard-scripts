#!/usr/bin/env bash
set -euo pipefail

# Remove WireGuard state created by this script bundle.
# This does not uninstall OS packages or remove unrelated WireGuard configs.

WG_IF_DEFAULT="wg0"
WG_DIR="/etc/wireguard"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENTS_DIR="${SCRIPT_DIR}/clients"
BACKUP_ROOT="${BACKUP_ROOT:-${SCRIPT_DIR}/install-backups}"

WG_IF="${WG_IF:-${WG_IF_DEFAULT}}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root:"
    echo "  sudo bash ${0}"
    exit 1
  fi
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

remove_path() {
  local path="$1"

  [[ -n "${path}" && "${path}" != "/" ]] || {
    echo "ERROR: refusing to remove unsafe path: ${path}" >&2
    exit 1
  }

  if [[ -e "${path}" ]]; then
    rm -rf "${path}"
    echo "Removed: ${path}"
  fi
}

stop_wireguard() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "wg-quick@${WG_IF}" 2>/dev/null || true
    systemctl disable "wg-quick@${WG_IF}" 2>/dev/null || true
  fi

  if command -v wg-quick >/dev/null 2>&1; then
    wg-quick down "${WG_IF}" 2>/dev/null || true
  fi
}

remove_ufw_rule() {
  local port_file="${SCRIPT_DIR}/server-port.txt"
  local port=""

  [[ -f "${port_file}" ]] || return 0
  port="$(cat "${port_file}")"
  [[ -n "${port}" ]] || return 0

  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
  fi
}

print_plan() {
  echo "This will remove WireGuard data created by this script bundle:"
  echo
  echo "  Interface service: wg-quick@${WG_IF}"
  echo "  Server config:     ${WG_DIR}/${WG_IF}.conf"
  echo "  Server keys:       ${WG_DIR}/server_private_key, ${WG_DIR}/server_public_key"
  echo "  Sysctl file:       /etc/sysctl.d/99-wireguard.conf"
  echo "  Client files:      ${CLIENTS_DIR}"
  echo "  Install backups:   ${BACKUP_ROOT}"
  echo "  Script state:      last-ip.txt, server-endpoint.txt, server-port.txt,"
  echo "                     server-interface.txt, server-net.txt"
  echo
  echo "It will also try to remove the UFW allow rule for the saved WireGuard UDP port."
  echo "It will not uninstall apt packages."
}

main() {
  require_root

  print_plan
  echo
  if ! confirm "Continue with uninstall?"; then
    echo "Aborted before making changes."
    exit 1
  fi

  stop_wireguard
  remove_ufw_rule

  remove_path "${WG_DIR}/${WG_IF}.conf"
  remove_path "${WG_DIR}/server_private_key"
  remove_path "${WG_DIR}/server_public_key"
  remove_path /etc/sysctl.d/99-wireguard.conf

  remove_path "${CLIENTS_DIR}"
  remove_path "${BACKUP_ROOT}"
  remove_path "${SCRIPT_DIR}/last-ip.txt"
  remove_path "${SCRIPT_DIR}/server-endpoint.txt"
  remove_path "${SCRIPT_DIR}/server-port.txt"
  remove_path "${SCRIPT_DIR}/server-interface.txt"
  remove_path "${SCRIPT_DIR}/server-net.txt"

  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system >/dev/null 2>&1 || true
  fi

  echo "Uninstall complete."
}

main "$@"
