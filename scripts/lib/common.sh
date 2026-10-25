#!/usr/bin/env bash
# Shared helpers for the AiPal mail-server scripts.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load .env if present (without clobbering already-exported vars)
if [[ -f "${REPO_ROOT}/.env" ]]; then
	# shellcheck disable=SC1091
	set -a; . "${REPO_ROOT}/.env"; set +a
fi

# ---- Defaults ---------------------------------------------------------------
: "${DOMAIN:=aipalassist.com}"
: "${MAIL_HOSTNAME:=mail.${DOMAIN}}"
: "${ADDITIONAL_SERVER_NAMES:=autodiscover.${DOMAIN},autoconfig.${DOMAIN}}"
: "${MAILCOW_TZ:=Europe/Paris}"
: "${MAILCOW_DIR:=/opt/mailcow-dockerized}"
: "${MAILCOW_HTTP_BIND:=127.0.0.1}"
: "${MAILCOW_HTTP_PORT:=8080}"
: "${MAILCOW_HTTPS_BIND:=127.0.0.1}"
: "${MAILCOW_HTTPS_PORT:=8443}"
: "${CADDYFILE:=/etc/caddy/Caddyfile}"
: "${CADDY_ENV_FILE:=/etc/caddy/status-auth.env}"
: "${CADDY_CERT_DIR:=/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory}"
: "${DMARC_RUA_MAILBOX:=dmarc@${DOMAIN}}"
: "${DMARC_POLICY:=none}"

# ---- Output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
	_C_RESET=$'\033[0m'; _C_BLUE=$'\033[1;34m'; _C_GREEN=$'\033[1;32m'
	_C_YELLOW=$'\033[1;33m'; _C_RED=$'\033[1;31m'; _C_DIM=$'\033[2m'
else
	_C_RESET=''; _C_BLUE=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''; _C_DIM=''
fi

log()  { printf '%s[*]%s %s\n' "${_C_BLUE}"   "${_C_RESET}" "$*"; }
ok()   { printf '%s[+]%s %s\n' "${_C_GREEN}"  "${_C_RESET}" "$*"; }
warn() { printf '%s[!]%s %s\n' "${_C_YELLOW}" "${_C_RESET}" "$*"; }
fail() { printf '%s[x]%s %s\n' "${_C_RED}"    "${_C_RESET}" "$*"; }
die()  { fail "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "${_C_DIM}" "------------------------------------------------------------" "${_C_RESET}"; }

require_root() {
	[[ ${EUID} -eq 0 ]] || die "This script must run as root (try: sudo $0)"
}

# ---- Public IP --------------------------------------------------------------
detect_public_ip() {
	if [[ -n "${VPS_IP:-}" ]]; then
		printf '%s' "${VPS_IP}"
		return
	fi
	curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
		|| curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
		|| true
}

# ---- mailcow.conf key/value editing ----------------------------------------
mc_conf() { printf '%s/mailcow.conf' "${MAILCOW_DIR}"; }

# get_conf KEY -> prints current value (empty if unset)
get_conf() {
	local key="$1" file
	file="$(mc_conf)"
	[[ -f "${file}" ]] || return 0
	sed -n "s/^${key}=//p" "${file}" | tail -n1
}

# set_conf KEY VALUE -> replaces existing key or appends; idempotent
set_conf() {
	local key="$1" value="$2" file tmp
	file="$(mc_conf)"
	[[ -f "${file}" ]] || die "mailcow.conf not found at ${file}"

	tmp="$(mktemp)"
	if grep -qE "^${key}=" "${file}"; then
		KEY="${key}" VAL="${value}" awk '
			BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
			$0 ~ ("^" k "=") { print k "=" v; next }
			{ print }
		' "${file}" > "${tmp}"
	else
		cp "${file}" "${tmp}"
		printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
	fi
	cat "${tmp}" > "${file}"   # preserves ownership/mode
	rm -f "${tmp}"
}

# ---- Misc checks ------------------------------------------------------------
docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# tcp_probe HOST PORT -> 0 if connect succeeds
tcp_probe() {
	local host="$1" port="$2"
	timeout 10 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# resolve_a RECORD -> prints first A record (empty if none)
resolve_a() {
	local name="$1"
	if command -v dig >/dev/null 2>&1; then
		dig +short A "${name}" @1.1.1.1 2>/dev/null | tail -n1
	else
		getent ahostsv4 "${name}" 2>/dev/null | awk 'NR==1{print $1}'
	fi
}

# resolve_txt RECORD -> prints TXT value(s) joined
resolve_txt() {
	local name="$1"
	command -v dig >/dev/null 2>&1 || return 0
	dig +short TXT "${name}" @1.1.1.1 2>/dev/null | tr -d '"' | paste -sd' ' -
}
