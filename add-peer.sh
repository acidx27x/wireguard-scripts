#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

SERVER_CONFIG="/etc/wireguard/wg0.conf"

usage() {
  echo "usage: add-peer.sh [--tmp|--live-only] <client_name>"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

validate_client_name() {
  local client_name="$1"

  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "client name may only contain letters, numbers, dot, underscore, and dash"
  [[ "${client_name}" != "." && "${client_name}" != ".." ]] || die "invalid client name"
}

client_ip() {
  local client_conf="$1"

  awk -F'[ =/]+' '$1 == "Address" {print $2; exit}' "${client_conf}"
}

add_peer_block() {
  local server_config="$1"
  local client_name="$2"
  local pub_key="$3"
  local ip="$4"
  local tmp_file=""

  tmp_file="$(mktemp)"
  cp "${server_config}" "${tmp_file}"
  {
    printf '\n[Peer]\n'
    printf '# %s\n' "${client_name}"
    printf 'PublicKey = %s\n' "${pub_key}"
    printf 'AllowedIPs = %s/32\n' "${ip}"
  } >> "${tmp_file}"

  sudo install -m 600 "${tmp_file}" "${server_config}"
  rm -f "${tmp_file}"
}

main() {
  local live_only=0

  if [[ $# -eq 2 ]]; then
    case "$1" in
      --tmp|--live-only) live_only=1; shift ;;
      *) usage; exit 1 ;;
    esac
  fi

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local client_name="$1"
  local client_dir=""
  local client_conf=""
  local pub_key_file=""
  local pub_key=""
  local ip=""

  validate_client_name "${client_name}"

  client_dir="clients/${client_name}"
  client_conf="${client_dir}/wg0.conf"
  pub_key_file="${client_dir}/${client_name}.pub"

  [[ -d "${client_dir}" ]] || die "client does not exist: ${client_name}"
  [[ -f "${client_conf}" ]] || die "client config is missing: ${client_conf}"
  [[ -f "${pub_key_file}" ]] || die "client public key is missing: ${pub_key_file}"

  pub_key="$(cat "${pub_key_file}")"
  ip="$(client_ip "${client_conf}")"
  [[ -n "${ip}" ]] || die "could not read client IP from ${client_conf}"

  if [[ "${live_only}" -eq 1 ]]; then
    sudo wg set wg0 peer "${pub_key}" allowed-ips "${ip}/32"
    sudo wg show
    exit 0
  fi

  [[ -f "${SERVER_CONFIG}" ]] || die "server config is missing: ${SERVER_CONFIG}"

  if grep -qF "${pub_key}" "${SERVER_CONFIG}"; then
    echo "Peer is already present in ${SERVER_CONFIG}"
  else
    if grep -qF "AllowedIPs = ${ip}/32" "${SERVER_CONFIG}"; then
      die "another peer already uses ${ip}/32 in ${SERVER_CONFIG}"
    fi

    add_peer_block "${SERVER_CONFIG}" "${client_name}" "${pub_key}" "${ip}"
    echo "Added peer to ${SERVER_CONFIG}"
  fi

  echo "Restart wg-quick@wg0 to apply this config change, or run add-peer.sh --tmp ${client_name} to add it to live wg0 now."
}

main "$@"
