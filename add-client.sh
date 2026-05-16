#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
  echo "usage: add-client.sh <client_name>"
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

client_exists_with_ip() {
  local ip="$1"
  local conf_file=""

  while IFS= read -r conf_file; do
    if grep -qF "Address = ${ip}/32" "${conf_file}"; then
      return 0
    fi
  done < <(find clients -mindepth 2 -maxdepth 2 -name wg0.conf -type f 2>/dev/null)

  return 1
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local client_name="$1"
  local client_dir=""
  local key=""
  local last_ip=""
  local ip=""
  local endpoint=""
  local server_endpoint=""
  local server_port=""
  local server_net=""
  local server_pub_key=""

  validate_client_name "${client_name}"

  [[ -f last-ip.txt ]] || die "last-ip.txt is missing; run install.sh first or create it with the server VPN IP"
  [[ -f wg0-client.example.conf ]] || die "wg0-client.example.conf is missing"
  [[ -f /etc/wireguard/server_public_key ]] || die "/etc/wireguard/server_public_key is missing"
  [[ -f /etc/wireguard/wg0.conf ]] || die "/etc/wireguard/wg0.conf is missing"

  client_dir="clients/${client_name}"
  [[ ! -e "${client_dir}" ]] || die "client already exists: ${client_name}"

  echo "Creating client config for: ${client_name}"
  last_ip="$(cat last-ip.txt)"
  ip="$(next_ip "${last_ip}")"

  if client_exists_with_ip "${ip}" >/dev/null; then
    die "next IP is already used by another client: ${ip}"
  fi

  endpoint="$(read_file_or_default server-endpoint.txt "$(hostname -f)")"
  server_port="$(read_file_or_default server-port.txt "51820")"
  server_endpoint="${endpoint}:${server_port}"
  server_net="$(read_file_or_default server-net.txt "10.8.0.0/24")"
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
    -e "s|:CLIENT_KEY:|${key}|g" \
    -e "s|:SERVER_PUB_KEY:|${server_pub_key}|g" \
    -e "s|:SERVER_ENDPOINT:|${server_endpoint}|g" \
    -e "s|:SERVER_NET:|${server_net}|g" \
    wg0-client.example.conf > "${client_dir}/wg0.conf"

  echo "Adding peer"
  bash "${SCRIPT_DIR}/add-peer.sh" "${client_name}"

  printf '%s\n' "${ip}" > last-ip.txt

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
    qrencode -t ansiutf8 < "${client_dir}/wg0.conf"
  fi
}

main "$@"
