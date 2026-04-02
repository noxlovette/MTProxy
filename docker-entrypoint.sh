#!/bin/sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
PORT="${PORT:-443}"
STATS_PORT="${STATS_PORT:-8888}"
WORKERS="${WORKERS:-1}"
MT_USER="${MT_USER:-mtproxy}"
CONFIG_URL="${CONFIG_URL:-https://core.telegram.org/getProxyConfig}"
SECRET_URL="${SECRET_URL:-https://core.telegram.org/getProxySecret}"
CONFIG_FILE="${CONFIG_FILE:-${DATA_DIR}/proxy-multi.conf}"
AES_SECRET_FILE="${AES_SECRET_FILE:-${DATA_DIR}/proxy-secret}"
SECRETS_FILE="${SECRETS_FILE:-${DATA_DIR}/secrets}"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

hex32() {
  printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f]{32}$'
}

generate_secret() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

write_secret_list() {
  target_file="$1"
  tmp_file="${target_file}.tmp"
  normalized_file="${target_file}.normalized"

  : > "${tmp_file}"
  printf '%s' "${SECRET}" | tr ',[:space:]' '\n' | sed '/^$/d' > "${normalized_file}"

  while IFS= read -r value; do
    if ! hex32 "${value}"; then
      rm -f "${normalized_file}" "${tmp_file}"
      die "SECRET entries must be exactly 32 hex characters: ${value}"
    fi
    printf '%s\n' "$(printf '%s' "${value}" | tr 'A-F' 'a-f')" >> "${tmp_file}"
  done < "${normalized_file}"

  rm -f "${normalized_file}"
  [ -s "${tmp_file}" ] || die "SECRET did not contain any usable values"
  mv "${tmp_file}" "${target_file}"
}

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

mkdir -p "${DATA_DIR}"

if [ "${REFRESH_PROXY_SECRET:-0}" = "1" ] || [ ! -s "${AES_SECRET_FILE}" ]; then
  log "[*] Downloading proxy secret to ${AES_SECRET_FILE}"
  curl -fsSL "${SECRET_URL}" -o "${AES_SECRET_FILE}.tmp"
  mv "${AES_SECRET_FILE}.tmp" "${AES_SECRET_FILE}"
fi

if [ "${REFRESH_PROXY_CONFIG:-1}" = "1" ] || [ ! -s "${CONFIG_FILE}" ]; then
  log "[*] Downloading proxy config to ${CONFIG_FILE}"
  curl -fsSL "${CONFIG_URL}" -o "${CONFIG_FILE}.tmp"
  mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
fi

if [ -n "${SECRET:-}" ]; then
  log "[*] Using secret(s) from SECRET env"
  write_secret_list "${SECRETS_FILE}"
elif [ ! -s "${SECRETS_FILE}" ]; then
  generated_secret="$(generate_secret)"
  log "[*] Generated secret ${generated_secret}"
  printf '%s\n' "${generated_secret}" > "${SECRETS_FILE}"
fi

if [ -n "${TAG:-}" ] && ! hex32 "${TAG}"; then
  die "TAG must be exactly 32 hex characters"
fi

case "${WORKERS}" in
  ''|*[!0-9]*)
    die "WORKERS must be a non-negative integer"
    ;;
esac

chmod 0600 "${AES_SECRET_FILE}" "${SECRETS_FILE}"

set -- /usr/local/bin/mtproto-proxy \
  -u "${MT_USER}" \
  -p "${STATS_PORT}" \
  -H "${PORT}" \
  --aes-pwd "${AES_SECRET_FILE}" "${CONFIG_FILE}" \
  -M "${WORKERS}"

if [ -n "${TAG:-}" ]; then
  set -- "$@" -P "$(printf '%s' "${TAG}" | tr 'A-F' 'a-f')"
fi

if [ -n "${NAT_INFO:-}" ]; then
  set -- "$@" --nat-info "${NAT_INFO}"
elif [ -n "${INTERNAL_IP:-}" ] && [ -n "${EXTERNAL_IP:-}" ]; then
  set -- "$@" --nat-info "${INTERNAL_IP}:${EXTERNAL_IP}"
fi

if [ -n "${TLS_DOMAIN:-}" ]; then
  set -- "$@" --domain "${TLS_DOMAIN}"
fi

while IFS= read -r secret; do
  [ -n "${secret}" ] || continue
  hex32 "${secret}" || die "Invalid persisted secret in ${SECRETS_FILE}: ${secret}"
  set -- "$@" -S "${secret}"
done < "${SECRETS_FILE}"

public_host="${PUBLIC_HOST:-${EXTERNAL_IP:-}}"
if [ -z "${public_host}" ]; then
  public_host="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi

log "[*] Final configuration:"
log "[*]   Data dir: ${DATA_DIR}"
log "[*]   Client port: ${PORT}"
log "[*]   Stats port: ${STATS_PORT}"
log "[*]   Workers: ${WORKERS}"
if [ -n "${TAG:-}" ]; then
  log "[*]   Tag: $(printf '%s' "${TAG}" | tr 'A-F' 'a-f')"
fi
if [ -n "${TLS_DOMAIN:-}" ]; then
  log "[*]   TLS domain: ${TLS_DOMAIN}"
fi
if [ -n "${NAT_INFO:-}" ]; then
  log "[*]   NAT info: ${NAT_INFO}"
elif [ -n "${INTERNAL_IP:-}" ] && [ -n "${EXTERNAL_IP:-}" ]; then
  log "[*]   NAT info: ${INTERNAL_IP}:${EXTERNAL_IP}"
fi

secret_index=1
while IFS= read -r secret; do
  [ -n "${secret}" ] || continue
  log "[*]   Secret ${secret_index}: ${secret}"
  if [ -n "${public_host}" ]; then
    log "[*]   tg:// link ${secret_index}: tg://proxy?server=${public_host}&port=${PORT}&secret=${secret}"
    log "[*]   t.me link ${secret_index}: https://t.me/proxy?server=${public_host}&port=${PORT}&secret=${secret}"
    log "[*]   tg:// padded ${secret_index}: tg://proxy?server=${public_host}&port=${PORT}&secret=dd${secret}"
  fi
  secret_index=$((secret_index + 1))
done < "${SECRETS_FILE}"

exec "$@"
