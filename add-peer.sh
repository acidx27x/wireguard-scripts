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

  awk -F= '
    $1 ~ /^[[:space:]]*Address[[:space:]]*$/ {
      split($2, addresses, ",")
      for (i in addresses) {
        address = addresses[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", address)
        split(address, parts, "/")
        if (index(parts[1], ":") == 0) {
          print parts[1]
          exit
        }
      }
    }
  ' "${client_conf}"
}

client_ip6() {
  local client_conf="$1"

  awk -F= '
    $1 ~ /^[[:space:]]*Address[[:space:]]*$/ {
      split($2, addresses, ",")
      for (i in addresses) {
        address = addresses[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", address)
        split(address, parts, "/")
        if (index(parts[1], ":") > 0) {
          print parts[1]
          exit
        }
      }
    }
  ' "${client_conf}"
}

add_peer_block() {
  local server_config="$1"
  local client_name="$2"
  local pub_key="$3"
  local ip="$4"
  local ip6="$5"
  local tmp_file=""
  local allowed_ips="${ip}/32"

  if [[ -n "${ip6}" ]]; then
    allowed_ips="${allowed_ips}, ${ip6}/128"
  fi

  tmp_file="$(mktemp)"
  cp "${server_config}" "${tmp_file}"
  {
    printf '\n[Peer]\n'
    printf '# %s\n' "${client_name}"
    printf 'PublicKey = %s\n' "${pub_key}"
    printf 'AllowedIPs = %s\n' "${allowed_ips}"
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
  local ip6=""
  local allowed_ips=""

  validate_client_name "${client_name}"

  client_dir="clients/${client_name}"
  client_conf="${client_dir}/wg0.conf"
  pub_key_file="${client_dir}/${client_name}.pub"

  [[ -d "${client_dir}" ]] || die "client does not exist: ${client_name}"
  [[ -f "${client_conf}" ]] || die "client config is missing: ${client_conf}"
  [[ -f "${pub_key_file}" ]] || die "client public key is missing: ${pub_key_file}"

  pub_key="$(cat "${pub_key_file}")"
  ip="$(client_ip "${client_conf}")"
  ip6="$(client_ip6 "${client_conf}")"
  [[ -n "${ip}" ]] || die "could not read client IP from ${client_conf}"
  allowed_ips="${ip}/32"
  if [[ -n "${ip6}" ]]; then
    allowed_ips="${allowed_ips},${ip6}/128"
  fi

  if [[ "${live_only}" -eq 1 ]]; then
    sudo wg set wg0 peer "${pub_key}" allowed-ips "${allowed_ips}"
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
    if [[ -n "${ip6}" ]] && grep -qF "${ip6}/128" "${SERVER_CONFIG}"; then
      die "another peer already uses ${ip6}/128 in ${SERVER_CONFIG}"
    fi

    add_peer_block "${SERVER_CONFIG}" "${client_name}" "${pub_key}" "${ip}" "${ip6}"
    echo "Added peer to ${SERVER_CONFIG}"
  fi

  echo "Restart wg-quick@wg0 to apply this config change, or run add-peer.sh --tmp ${client_name} to add it to live wg0 now."
}

main "$@"
