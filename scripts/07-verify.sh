#!/usr/bin/env bash
# End-to-end verification: DNS records, PTR, TLS, port 25 and containers.
#   ./scripts/07-verify.sh        (no root needed; run anywhere)
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IP="$(detect_public_ip)"
FAIL=0
pass() { ok   "$*"; }
bad()  { fail "$*"; FAIL=$((FAIL+1)); }

hr; log "Verifying ${DOMAIN} / ${MAIL_HOSTNAME} (IP ${IP})"; hr

# ---- DNS --------------------------------------------------------------------
log "DNS"
MAIL_A="$(resolve_a "${MAIL_HOSTNAME}")"
[[ "${MAIL_A}" == "${IP}" ]] && pass "A ${MAIL_HOSTNAME} -> ${MAIL_A}" \
	|| bad "A ${MAIL_HOSTNAME} -> '${MAIL_A:-<none>}' (expected ${IP})"

MX="$(dig +short MX "${DOMAIN}" @1.1.1.1 2>/dev/null | head -1)"
[[ "${MX}" == *"${MAIL_HOSTNAME}"* ]] && pass "MX ${DOMAIN} -> ${MX}" \
	|| bad "MX ${DOMAIN} -> '${MX:-<none>}' (expected ${MAIL_HOSTNAME})"

SPF="$(resolve_txt "${DOMAIN}" || true)"
if [[ "${SPF}" == *v=spf1* ]]; then
	pass "SPF present: ${SPF}"
	[[ "${SPF}" == *"${IP}"* || "${SPF}" == *mx* ]] && pass "SPF authorises this server" \
		|| bad "SPF does not cover this server"
else
	bad "SPF missing on ${DOMAIN}"
fi

DKIM_TXT="$(resolve_txt "dkim._domainkey.${DOMAIN}" || true)"
[[ "${DKIM_TXT}" == *DKIM1* || "${DKIM_TXT}" == *p=* ]] && pass "DKIM present (${#DKIM_TXT} chars)" \
	|| bad "DKIM missing at dkim._domainkey.${DOMAIN}"

DMARC="$(resolve_txt "_dmarc.${DOMAIN}" || true)"
[[ "${DMARC}" == *v=DMARC1* ]] && pass "DMARC present: ${DMARC}" || bad "DMARC missing on _dmarc.${DOMAIN}"

PTR="$(dig +short -x "${IP}" @1.1.1.1 2>/dev/null | head -1 | sed 's/\.$//')"
[[ "${PTR}" == "${MAIL_HOSTNAME}" ]] && pass "PTR ${IP} -> ${PTR}" \
	|| bad "PTR ${IP} -> '${PTR:-<none>}' (expected ${MAIL_HOSTNAME})"
echo

# ---- Connectivity -----------------------------------------------------------
log "Connectivity"
tcp_probe gmail-smtp-in.l.google.com 25 && pass "outbound TCP/25 works" || bad "outbound TCP/25 blocked"
for p in 25 465 587 143 993; do
	tcp_probe "${MAIL_HOSTNAME}" "${p}" && pass "inbound TCP/${p} open" || bad "inbound TCP/${p} unreachable"
done
echo

# ---- TLS --------------------------------------------------------------------
log "TLS"
for spec in "993 IMAP" "465 SMTPS" "587 SUBMISSION"; do
	port="${spec%% *}"; label="${spec##* }"
	subj="$(echo | timeout 10 openssl s_client -connect "${MAIL_HOSTNAME}:${port}" \
		-servername "${MAIL_HOSTNAME}" 2>/dev/null \
		| openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')"
	if [[ -n "${subj}" ]]; then
		[[ "${subj}" == *"${MAIL_HOSTNAME}"* ]] && pass "${label}:${port} cert = ${subj}" \
			|| bad "${label}:${port} cert mismatch: ${subj}"
	else
		bad "${label}:${port} no TLS response"
	fi
done

if curl -fsS -o /dev/null --max-time 10 "https://${MAIL_HOSTNAME}/" 2>/dev/null; then
	pass "https://${MAIL_HOSTNAME}/ reachable"
else
	bad "https://${MAIL_HOSTNAME}/ not reachable"
fi
echo

# ---- Containers (if run on the server) --------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
	log "mailcow containers"
	DOWN="$(docker ps -a --filter "name=mailcow" --format '{{.Names}}\t{{.Status}}' 2>/dev/null \
		| grep -viE 'up' | wc -l)"
	[[ "${DOWN}" -eq 0 ]] && pass "all mailcow containers up" || warn "${DOWN} container(s) not running"
	docker ps --filter "name=mailcow" --format '  {{.Names}}  {{.Status}}' 2>/dev/null | head -20
fi

hr
if [[ ${FAIL} -eq 0 ]]; then
	ok "All checks passed — send a test mail to https://www.mail-tester.com/ and confirm 10/10"
else
	warn "${FAIL} check(s) failed — see docs/05-troubleshooting.md"
	exit 1
fi
