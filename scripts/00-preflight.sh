#!/usr/bin/env bash
# Read-only preflight report. Changes nothing; run this first.
#   sudo ./scripts/00-preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IP="$(detect_public_ip)"
PASS=0; FAIL=0
# Override the shared helpers so the report can count outcomes
ok()   { printf '%s[+]%s %s\n' "${_C_GREEN}"  "${_C_RESET}" "$*"; PASS=$((PASS+1)); }
fail() { printf '%s[x]%s %s\n' "${_C_RED}"    "${_C_RESET}" "$*"; FAIL=$((FAIL+1)); }

hr; log "AiPal mail server preflight — ${MAIL_HOSTNAME}"; hr

# ---- OS ---------------------------------------------------------------------
log "Host"
printf '  hostname : %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf '  os       : %s\n' "$(. /etc/os-release && echo "${PRETTY_NAME}")"
printf '  kernel   : %s\n' "$(uname -r)"
printf '  public ip: %s\n' "${IP:-<unknown>}"
printf '  tz       : %s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
echo

# ---- Resources --------------------------------------------------------------
log "Resources"
MEM_GIB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
DISK_AVAIL_GIB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
printf '  ram      : %s GiB (mailcow minimum: 6 GiB)\n' "${MEM_GIB}"
printf '  disk free: %s GiB (minimum: 20 GiB)\n' "${DISK_AVAIL_GIB}"
printf '  swap     : %s MiB %s\n' "${SWAP_MB}" "$([[ ${SWAP_MB} -ge 512 ]] && echo '' || echo '(mailcow recommends >= 1 GiB)')"
[[ ${MEM_GIB} -ge 6 ]] && ok "RAM meets mailcow minimum" || fail "RAM below 6 GiB"
[[ ${DISK_AVAIL_GIB} -ge 20 ]] && ok "Disk meets mailcow minimum" || fail "Disk below 20 GiB"
[[ ${SWAP_MB} -ge 512 ]] && ok "Swap present" || warn "No/low swap — scripts/01-bootstrap-host.sh will add 2 GiB"
echo

# ---- Docker -----------------------------------------------------------------
log "Docker"
if command -v docker >/dev/null 2>&1; then
	printf '  version   : %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'daemon down')"
	printf '  compose   : %s\n' "$(docker compose version --short 2>/dev/null || echo 'missing')"
	docker info >/dev/null 2>&1 && ok "Docker daemon reachable" || fail "Docker daemon unreachable"
else
	fail "Docker not installed"
fi
echo

# ---- Port 25 egress (the make-or-break test) --------------------------------
log "Port 25 egress (outbound delivery)"
for h in gmail-smtp-in.l.google.com aspmx.l.google.com; do
	if tcp_probe "${h}" 25; then ok "TCP 25 -> ${h} open"; else fail "TCP 25 -> ${h} blocked"; fi
done
echo

# ---- Listener conflicts -----------------------------------------------------
log "Port availability"
for p in 25 465 587 143 993 110 995 4190 8080 8443; do
	if ss -tlnH "sport = :${p}" 2>/dev/null | grep -q .; then
		fail "port ${p} already in use"
	else
		ok "port ${p} free"
	fi
done
# 80/443 are expected to be taken by Caddy
for p in 80 443; do
	if ss -tlnH "sport = :${p}" 2>/dev/null | grep -q .; then
		printf '  note: port %s in use (expected — Caddy fronts mailcow on 8080)\n' "${p}"
	fi
done
echo

# ---- DNS state --------------------------------------------------------------
log "DNS state for ${DOMAIN}"
MAIL_A="$(resolve_a "${MAIL_HOSTNAME}")"
printf '  %-28s A    -> %s\n' "${MAIL_HOSTNAME}" "${MAIL_A:-<none>}"
printf '  %-28s MX   -> %s\n' "${DOMAIN}" "$(dig +short MX "${DOMAIN}" @1.1.1.1 2>/dev/null | tr '\n' ' ' || true)"
printf '  %-28s SPF  -> %s\n' "${DOMAIN}" "$(resolve_txt "${DOMAIN}" || true)"
printf '  %-28s DMARC-> %s\n' "_dmarc.${DOMAIN}" "$(resolve_txt "_dmarc.${DOMAIN}" || true)"

if [[ -n "${MAIL_A}" && -n "${IP}" && "${MAIL_A}" == "${IP}" ]]; then
	ok "${MAIL_HOSTNAME} resolves to this server"
elif [[ -z "${MAIL_A}" ]]; then
	warn "${MAIL_HOSTNAME} has no A record yet — set it before installing (docs/02-dns-godaddy.md)"
else
	fail "${MAIL_HOSTNAME} resolves to ${MAIL_A}, expected ${IP}"
fi

PTR_HOST="$(dig +short -x "${IP}" @1.1.1.1 2>/dev/null | head -1 | sed 's/\.$//')"
printf '  PTR %-23s -> %s\n' "${IP}" "${PTR_HOST:-<none>}"
if [[ "${PTR_HOST}" == "${MAIL_HOSTNAME}" ]]; then
	ok "PTR matches ${MAIL_HOSTNAME}"
else
	warn "PTR is '${PTR_HOST:-none}', should be '${MAIL_HOSTNAME}' (set in hPanel; strong deliverability factor)"
fi
echo

# ---- Blocklist reputation ---------------------------------------------------
log "IP reputation (DNSBL) for ${IP}"
REV_IP="$(echo "${IP}" | awk -F. '{print $4"."$3"."$2"."$1}')"
LISTED=0
for bl in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org dnsbl.sorbs.net cbl.abuseat.org; do
	if command -v dig >/dev/null 2>&1 && [[ -n "$(dig +short +time=4 +tries=1 "${REV_IP}.${bl}" A 2>/dev/null | head -1)" ]]; then
		fail "listed on ${bl}"; LISTED=$((LISTED+1))
	fi
done
[[ ${LISTED} -eq 0 ]] && ok "not listed on the major blocklists" || warn "${LISTED} blocklist(s) flag this IP — expect deliverability work"
echo

hr
printf '  %s passed, %s failed\n' "${PASS}" "${FAIL}"
hr
[[ ${FAIL} -eq 0 ]] && ok "Preflight looks good" || warn "Resolve the failures above before installing"
