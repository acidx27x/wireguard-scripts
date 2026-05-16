#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
  echo "usage: add-client.sh [--ipv6-endpoint] <client_name>"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

read_file_or_default() {
  local file="$1"
  local default="$2"

  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    printf '%s\n' "${default}"
  fi
}

validate_client_name() {
  local client_name="$1"

  [[ "${client_name}" =~ ^[A-Za-z0-9._-]+$ ]] || die "client name may only contain letters, numbers, dot, underscore, and dash"
  [[ "${client_name}" != "." && "${client_name}" != ".." ]] || die "invalid client name"
}

next_ip() {
  local last_ip="$1"
  local oct1=""
  local oct2=""
  local oct3=""
  local oct4=""

  IFS=. read -r oct1 oct2 oct3 oct4 <<< "${last_ip}"
  [[ "${oct1}" =~ ^[0-9]+$ && "${oct2}" =~ ^[0-9]+$ && "${oct3}" =~ ^[0-9]+$ && "${oct4}" =~ ^[0-9]+$ ]] || die "last-ip.txt contains invalid IPv4 address: ${last_ip}"
  (( oct1 >= 0 && oct1 <= 255 && oct2 >= 0 && oct2 <= 255 && oct3 >= 0 && oct3 <= 255 )) || die "last-ip.txt contains invalid IPv4 address: ${last_ip}"
  (( oct4 >= 1 && oct4 < 254 )) || die "no usable client IPs remain after ${last_ip}"

  printf '%s.%s.%s.%s\n' "${oct1}" "${oct2}" "${oct3}" "$((oct4 + 1))"
}

next_ip6() {
  local last_ip="$1"
  local prefix=""
  local suffix=""
  local next_suffix=""

  [[ "${last_ip}" == *:* ]] || die "last-ip6.txt contains invalid IPv6 address: ${last_ip}"

  prefix="${last_ip%:*}"
  suffix="${last_ip##*:}"

  if [[ -z "${suffix}" ]]; then
    die "last-ip6.txt must include a host segment, for example fd42:42:42::1"
  fi
  [[ "${suffix}" =~ ^[0-9A-Fa-f]+$ ]] || die "last-ip6.txt contains invalid IPv6 address: ${last_ip}"
  (( 16#${suffix} < 16#ffff )) || die "no usable IPv6 client IPs remain after ${last_ip}"

  printf -v next_suffix '%x' "$((16#${suffix} + 1))"
  printf '%s:%s\n' "${prefix}" "${next_suffix}"
}

client_exists_with_ip() {
  local ip="$1"
  local conf_file=""

  while IFS= read -r conf_file; do
    if grep -qF "${ip}/" "${conf_file}"; then
      return 0
    fi
  done < <(find clients -mindepth 2 -maxdepth 2 -name wg0.conf -type f 2>/dev/null)

  return 1
}

format_endpoint() {
  local endpoint="$1"
  local port="$2"

  if [[ "${endpoint}" == \[*\]:* ]]; then
    printf '%s\n' "${endpoint}"
  elif [[ "${endpoint}" == \[*\] ]]; then
    printf '%s:%s\n' "${endpoint}" "${port}"
  elif [[ "${endpoint}" =~ ^[^:]+:[0-9]+$ ]]; then
    printf '%s\n' "${endpoint}"
  elif [[ "${endpoint}" == *:* ]]; then
    printf '[%s]:%s\n' "${endpoint}" "${port}"
  else
    printf '%s:%s\n' "${endpoint}" "${port}"
  fi
}

main() {
  local endpoint_source="ipv4"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ipv6-endpoint)
        endpoint_source="ipv6"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local client_name="$1"
  local client_dir=""
  local key=""
  local last_ip=""
  local last_ip6=""
  local ip=""
  local ip6=""
  local endpoint=""
  local server_endpoint=""
  local server_port=""
  local server_net=""
  local server_net6=""
  local server_pub_key=""

  validate_client_name "${client_name}"

  [[ -f last-ip.txt ]] || die "last-ip.txt is missing; run install.sh first or create it with the server VPN IP"
  [[ -f last-ip6.txt ]] || die "last-ip6.txt is missing; run install.sh first or create it with the server IPv6 VPN IP"
  [[ -f wg0-client.example.conf ]] || die "wg0-client.example.conf is missing"
  [[ -f /etc/wireguard/server_public_key ]] || die "/etc/wireguard/server_public_key is missing"
  [[ -f /etc/wireguard/wg0.conf ]] || die "/etc/wireguard/wg0.conf is missing"

  client_dir="clients/${client_name}"
  [[ ! -e "${client_dir}" ]] || die "client already exists: ${client_name}"

  echo "Creating client config for: ${client_name}"
  last_ip="$(cat last-ip.txt)"
  last_ip6="$(cat last-ip6.txt)"
  ip="$(next_ip "${last_ip}")"
  ip6="$(next_ip6 "${last_ip6}")"

  if client_exists_with_ip "${ip}" >/dev/null; then
    die "next IP is already used by another client: ${ip}"
  fi
  if client_exists_with_ip "${ip6}" >/dev/null; then
    die "next IPv6 is already used by another client: ${ip6}"
  fi

  server_port="$(read_file_or_default server-port.txt "51820")"
  case "${endpoint_source}" in
    ipv6)
      [[ -f server-endpoint6.txt ]] || die "server-endpoint6.txt is missing; run install.sh again or create it with the public IPv6 endpoint"
      endpoint="$(cat server-endpoint6.txt)"
      [[ -n "${endpoint}" ]] || die "server-endpoint6.txt is empty"
      ;;
    *)
      endpoint="$(read_file_or_default server-endpoint.txt "$(hostname -f)")"
      ;;
  esac
  server_endpoint="$(format_endpoint "${endpoint}" "${server_port}")"
  server_net="$(read_file_or_default server-net.txt "10.8.0.0/24")"
  server_net6="$(read_file_or_default server-net6.txt "fd42:42:42::/64")"
  server_pub_key="$(cat /etc/wireguard/server_public_key)"

  mkdir -p "${client_dir}"
  chmod 700 "${client_dir}"

  (
    umask 077
    wg genkey | tee "${client_dir}/${client_name}.priv" | wg pubkey > "${client_dir}/${client_name}.pub"
  )
  key="$(cat "${client_dir}/${client_name}.priv")"

  sed \
    -e "s|:CLIENT_IP:|${ip}|g" \
    -e "s|:CLIENT_IP6:|${ip6}|g" \
    -e "s|:CLIENT_KEY:|${key}|g" \
    -e "s|:SERVER_PUB_KEY:|${server_pub_key}|g" \
    -e "s|:SERVER_ENDPOINT:|${server_endpoint}|g" \
    -e "s|:SERVER_NET:|${server_net}|g" \
    -e "s|:SERVER_NET6:|${server_net6}|g" \
    wg0-client.example.conf > "${client_dir}/wg0.conf"

  echo "Adding peer"
  bash "${SCRIPT_DIR}/add-peer.sh" "${client_name}"

  printf '%s\n' "${ip}" > last-ip.txt
  printf '%s\n' "${ip6}" > last-ip6.txt

  if ! bash "${SCRIPT_DIR}/add-peer.sh" --tmp "${client_name}"; then
    echo "WARNING: peer was added to /etc/wireguard/wg0.conf but not to live wg0"
  fi

  echo "Adding peer to hosts file"
  if ! awk -v ip="${ip}" -v name="${client_name}" '$1 == ip && $2 == name { found = 1 } END { exit !found }' /etc/hosts 2>/dev/null; then
    printf '%s %s\n' "${ip}" "${client_name}" | sudo tee -a /etc/hosts >/dev/null
  fi

  echo "Created config: ${client_dir}/wg0.conf"
  sudo wg show || true
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "${client_dir}/wg0.conf" | tee "${client_dir}/wg0-qrcode.txt"
    echo "Created QR code text: ${client_dir}/wg0-qrcode.txt"
  fi
}

main "$@"
