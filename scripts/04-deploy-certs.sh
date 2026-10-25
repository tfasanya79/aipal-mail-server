#!/usr/bin/env bash
# Share Caddy's Let's Encrypt certificate with mailcow, so SMTP/IMAP (465/587/
# 993) present the same certificate as the web UI. Mailcow's own ACME client is
# disabled (SKIP_LETS_ENCRYPT=y), so this is the only cert source.
#
# Safe to run repeatedly: only restarts containers when the cert actually
# changed. Installs an hourly cron job.
#   sudo ./scripts/04-deploy-certs.sh [--no-cron]
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_root

NO_CRON=0
[[ "${1:-}" == "--no-cron" ]] && NO_CRON=1

hr; log "Deploying Caddy certificate into mailcow"; hr

SRC_DIR="${CADDY_CERT_DIR}/${MAIL_HOSTNAME}"
SRC_CRT="${SRC_DIR}/${MAIL_HOSTNAME}.crt"
SRC_KEY="${SRC_DIR}/${MAIL_HOSTNAME}.key"
SSL_DIR="${MAILCOW_DIR}/data/assets/ssl"

[[ -f "${SRC_CRT}" ]] || die "Caddy cert not found: ${SRC_CRT}
     DNS A record set and 'systemctl reload caddy' run? See docs/02-dns-godaddy.md"
[[ -f "${SRC_KEY}" ]] || die "Caddy key not found: ${SRC_KEY}"
[[ -d "${SSL_DIR}" ]] || die "mailcow ssl dir not found: ${SSL_DIR} (run scripts/02-install-mailcow.sh)"

md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

CUR="$(md5of "${SSL_DIR}/cert.pem")"
NEW="$(md5of "${SRC_CRT}")"

if [[ "${CUR}" == "${NEW}" ]]; then
	ok "Certificate unchanged — nothing to do"
else
	log "Installing new certificate"
	install -m 0644 "${SRC_CRT}" "${SSL_DIR}/cert.pem"
	install -m 0640 "${SRC_KEY}" "${SSL_DIR}/key.pem"

	# Per-hostname layout (used when ENABLE_SSL_SNI would be enabled)
	mkdir -p "${SSL_DIR}/${MAIL_HOSTNAME}"
	install -m 0644 "${SRC_CRT}" "${SSL_DIR}/${MAIL_HOSTNAME}/cert.pem"
	install -m 0640 "${SRC_KEY}" "${SSL_DIR}/${MAIL_HOSTNAME}/key.pem"

	log "Restarting postfix/dovecot/nginx to pick up the new cert"
	for svc in postfix-mailcow dovecot-mailcow nginx-mailcow; do
		cid="$(docker ps -qaf "name=${svc}")"
		[[ -n "${cid}" ]] && docker restart "${cid}" >/dev/null && ok "restarted ${svc}"
	done
	ok "Certificate deployed and services restarted"
fi

# ---- Verify what the mail services actually present -------------------------
echo
log "Waiting for mail services to listen again"
for _ in $(seq 1 20); do
	ss -tlnH "sport = :993" 2>/dev/null | grep -q . && break
	sleep 2
done

log "Verifying certificate presented on mail ports"
# probe_tls PORT STARTTLS?  — 587 speaks plaintext then upgrades, so it needs
# -starttls smtp; 993/465 are implicit TLS.
probe_tls() {
	local port="$1" mode="${2:-}" extra=() subj
	[[ "${mode}" == "starttls" ]] && extra=(-starttls smtp)
	subj="$(echo | timeout 10 openssl s_client -connect "127.0.0.1:${port}" \
		-servername "${MAIL_HOSTNAME}" "${extra[@]}" 2>/dev/null \
		| openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
	printf '%s' "${subj}"
}

for spec in "993 IMAP implicit" "465 SMTPS implicit" "587 SUBMISSION starttls"; do
	set -- ${spec}
	port="$1"; label="$2"; mode="$3"
	actual="$(probe_tls "${port}" "${mode}")"
	if [[ -n "${actual}" ]]; then
		printf '  %-11s :%s -> %s\n' "${label}" "${port}" "${actual}"
	else
		warn "${label} :${port} did not present a certificate (container up?)"
	fi
done

# ---- Cron -------------------------------------------------------------------
if [[ ${NO_CRON} -eq 0 ]]; then
	SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
	CRON_LINE="17 * * * * ${SCRIPT_PATH} --no-cron >>/var/log/aipal-deploy-certs.log 2>&1"
	if crontab -l 2>/dev/null | grep -qF "${SCRIPT_PATH} --no-cron"; then
		ok "Hourly cron already installed"
	else
		( crontab -l 2>/dev/null; echo "${CRON_LINE}" ) | crontab -
		ok "Installed hourly cron: ${CRON_LINE}"
	fi
fi

hr
ok "Done. Renewals now propagate to mailcow automatically within an hour."
hr
