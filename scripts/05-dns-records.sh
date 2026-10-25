#!/usr/bin/env bash
# Emit the exact DNS records to enter in GoDaddy, including the DKIM public key
# that mailcow generated. Run this AFTER adding the domain in the mailcow UI.
#   sudo ./scripts/05-dns-records.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

IP="$(detect_public_ip)"

db_q() { # db_q "<sql>"
	local sql="$1" conf="${MAILCOW_DIR}/mailcow.conf"
	[[ -f "${conf}" ]] || return 0
	local dbpass dbuser dbname
	dbpass="$(sed -n 's/^DBPASS=//p' "${conf}" | tail -1)"
	dbuser="$(sed -n 's/^DBUSER=//p' "${conf}" | tail -1)"; : "${dbuser:=mailcow}"
	dbname="$(sed -n 's/^DBNAME=//p' "${conf}" | tail -1)"; : "${dbname:=mailcow}"
	docker exec -e MYSQL_PWD="${dbpass}" mysql-mailcow \
		mysql -u "${dbuser}" -N -B "${dbname}" -e "${sql}" 2>/dev/null
}

# ---- Pull DKIM from mailcow -------------------------------------------------
DKIM_SELECTOR="dkim"
DKIM_VALUE=""
ROW="$(db_q "SELECT dkim_selector, dkim_pubkey FROM domain WHERE domain='${DOMAIN}';" || true)"
if [[ -n "${ROW}" ]]; then
	DKIM_SELECTOR="$(echo "${ROW}" | cut -f1)"; : "${DKIM_SELECTOR:=dkim}"
	DKIM_VALUE="$(echo "${ROW}" | cut -f2)"
	# Normalise to a full DKIM TXT value
	if [[ -n "${DKIM_VALUE}" && "${DKIM_VALUE}" != v=DKIM1* ]]; then
		DKIM_VALUE="v=DKIM1; k=rsa; p=${DKIM_VALUE}"
	fi
fi

SPF="v=spf1 mx ~all"
DMARC="v=DMARC1; p=${DMARC_POLICY}; rua=mailto:${DMARC_RUA_MAILBOX}; adkim=r; aspf=r; pct=100"

hr; log "GoDaddy DNS records for ${DOMAIN}  (TTL: 1 hour / 3600)"; hr

cat <<EOF

  ┌─ A ────────────────────────────────────────────────────────────────────
  │ Type : A
  │ Name : mail
  │ Value: ${IP}
  │ TTL  : 3600
  └────────────────────────────────────────────────────────────────────────

  ┌─ MX  (where mail for @${DOMAIN} is delivered) ────────────────────────
  │ Type    : MX
  │ Name    : @
  │ Value   : ${MAIL_HOSTNAME}
  │ Priority: 10
  │ TTL     : 3600
  └────────────────────────────────────────────────────────────────────────

  ┌─ TXT / SPF  (WHO may send mail as @${DOMAIN}) ────────────────────────
  │ Type : TXT
  │ Name : @
  │ Value: ${SPF}
  │ TTL  : 3600
  └────────────────────────────────────────────────────────────────────────

  ┌─ TXT / DKIM  (cryptographic signature) ───────────────────────────────
  │ Type : TXT
  │ Name : ${DKIM_SELECTOR}._domainkey
  │ Value: ${DKIM_VALUE:-<ADD THE DOMAIN IN MAILCOW FIRST — key not found>}
  │ TTL  : 3600
  └────────────────────────────────────────────────────────────────────────

  ┌─ TXT / DMARC  (policy + reporting) ───────────────────────────────────
  │ Type : TXT
  │ Name : _dmarc
  │ Value: ${DMARC}
  │ TTL  : 3600
  └────────────────────────────────────────────────────────────────────────
EOF

# ---- Optional autodiscover/autoconfig --------------------------------------
if [[ -n "${ADDITIONAL_SERVER_NAMES:-}" ]]; then
	echo "  ┌─ A (optional: Outlook / Thunderbird autodiscovery) ──────────────────"
	IFS=',' read -r -a EXTRA <<< "${ADDITIONAL_SERVER_NAMES}"
	for n in "${EXTRA[@]}"; do
		[[ -z "${n}" ]] && continue
		printf '  │ A  %-45s -> %s\n' "${n}" "${IP}"
	done
	echo "  └────────────────────────────────────────────────────────────────────────"
	echo
fi

# ---- PTR --------------------------------------------------------------------
hr
log "PTR (reverse DNS) — set this in Hostinger hPanel, NOT GoDaddy"
echo "  IPv4 : ${IP}"
echo "  PTR  : ${MAIL_HOSTNAME}"
echo "  Path : hPanel → VPS → your server → Network / IPv4 → Reverse DNS (PTR)"
echo "  Then : confirm with  dig +short -x ${IP}"
echo

# ---- Warnings based on live state ------------------------------------------
hr
CURRENT_DMARC="$(resolve_txt "_dmarc.${DOMAIN}" || true)"
if [[ -n "${CURRENT_DMARC}" ]]; then
	warn "A DMARC record already exists and may be GoDaddy's default:"
	printf '       %s\n' "${CURRENT_DMARC}"
	warn "Edit that record to the value above instead of creating a second one."
	[[ "${CURRENT_DMARC}" == *onsecureserver.net* ]] && \
		warn "Detected GoDaddy's default rua aggregator — replacing it is fine."
fi
CURRENT_SPF="$(resolve_txt "${DOMAIN}" || true)"
if [[ -n "${CURRENT_SPF}" && "${CURRENT_SPF}" == *spf1* && "${CURRENT_SPF}" != *"${SPF}"* ]]; then
	warn "An SPF record already exists: ${CURRENT_SPF}"
	warn "A domain must have exactly ONE SPF record — merge, don't add."
fi
hr
log "After entering the records, verify with: sudo ./scripts/07-verify.sh"
