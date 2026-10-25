#!/usr/bin/env bash
# Teach the EXISTING Caddy instance to serve mail.aipalassist.com and proxy it
# to mailcow's loopback nginx. Validates before reloading, and rolls back if the
# new Caddyfile would be invalid — your other sites must not break.
#   sudo ./scripts/03-caddy-setup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_root

BEGIN_MARK='# >>> aipal-mail-server (managed block — do not hand-edit) >>>'
END_MARK='# <<< aipal-mail-server <<<'

hr; log "Configuring Caddy for ${MAIL_HOSTNAME}"; hr

[[ -f "${CADDYFILE}" ]] || die "Caddyfile not found at ${CADDYFILE}"
command -v caddy >/dev/null 2>&1 || die "caddy binary not found"

# ---- Build the managed block ------------------------------------------------
SITE_NAMES="${MAIL_HOSTNAME}"
if [[ -n "${ADDITIONAL_SERVER_NAMES:-}" ]]; then
	IFS=',' read -r -a EXTRA_NAMES <<< "${ADDITIONAL_SERVER_NAMES}"
	for n in "${EXTRA_NAMES[@]}"; do
		[[ -n "${n}" ]] && SITE_NAMES="${SITE_NAMES}, ${n}"
	done
fi

BLOCK="$(cat <<EOF
${BEGIN_MARK}
# ${MAIL_HOSTNAME} -> mailcow nginx on 127.0.0.1:${MAILCOW_HTTP_PORT}
# Caddy terminates TLS here; mailcow's own ACME is disabled
# (SKIP_LETS_ENCRYPT=y) and reuses this certificate.
${SITE_NAMES} {
	encode zstd gzip

	log {
		output file /var/log/caddy/aipal-mail-access.log {
			roll_size 10MiB
			roll_keep 5
		}
		format json
	}

	# Mailcow's nginx on HTTP_PORT does an unconditional 301 to the HTTPS URL
	# (location / { return 301 ...; }), so a plain-HTTP upstream loops forever.
	# Proxy the TLS port instead and keep the Host header.
	# Loopback only, so skipping chain verification is acceptable; mailcow uses
	# a single cert (ENABLE_SSL_SNI=n) that may not match every hostname.
	reverse_proxy https://127.0.0.1:${MAILCOW_HTTPS_PORT} {
		header_up Host {host}
		transport http {
			tls
			tls_server_name ${MAIL_HOSTNAME}
			tls_insecure_skip_verify
		}
		flush_interval -1
	}
}
${END_MARK}
EOF
)"

# ---- Back up, strip any previous block, append the new one ------------------
BACKUP="${CADDYFILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "${CADDYFILE}" "${BACKUP}"
ok "Backed up Caddyfile -> ${BACKUP}"

TMP="$(mktemp)"
awk -v b="${BEGIN_MARK}" -v e="${END_MARK}" '
	$0 == b { skip = 1; next }
	$0 == e { skip = 0; next }
	!skip   { print }
' "${CADDYFILE}" > "${TMP}"

# Guarantee a separating newline before appending
[[ -s "${TMP}" && "$(tail -c1 "${TMP}")" != "" ]] && printf '\n' >> "${TMP}"
printf '%s\n' "${BLOCK}" >> "${TMP}"
install -m 0644 -o root -g root "${TMP}" "${CADDYFILE}"
rm -f "${TMP}"
ok "Managed block written"

# ---- Validate with the service environment loaded ---------------------------
log "Validating Caddyfile (with ${CADDY_ENV_FILE} loaded)"
# systemd EnvironmentFile is raw KEY=value (no shell expansion), so pass each
# line to `env` verbatim rather than sourcing it — the basic-auth hash contains
# '$' characters that must not be expanded.
ENV_ARGS=()
if [[ -f "${CADDY_ENV_FILE}" ]]; then
	while IFS= read -r line; do
		case "${line}" in ''|'#'*) continue ;; esac
		ENV_ARGS+=("${line}")
	done < "${CADDY_ENV_FILE}"
fi

VALID_OUT="$(env "${ENV_ARGS[@]}" caddy validate --config "${CADDYFILE}" --adapter caddyfile 2>&1)" \
	&& VALID_RC=0 || VALID_RC=$?

if [[ ${VALID_RC} -ne 0 ]]; then
	printf '%s\n' "${VALID_OUT}" | tail -n 15
	cp -a "${BACKUP}" "${CADDYFILE}"
	die "Caddyfile INVALID — rolled back to ${BACKUP}. Nothing was reloaded."
fi
ok "Caddyfile is valid"

# ---- Reload -----------------------------------------------------------------
log "Reloading Caddy"
if systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null; then
	sleep 2
	systemctl is-active --quiet caddy && ok "Caddy reloaded (active)" || die "Caddy is not active after reload"
else
	cp -a "${BACKUP}" "${CADDYFILE}"
	systemctl restart caddy 2>/dev/null || true
	die "Reload failed — restored ${BACKUP}"
fi

# ---- Wait for the certificate ----------------------------------------------
log "Waiting for Caddy to obtain a certificate for ${MAIL_HOSTNAME} (up to 90s)"
CERT_PATH="${CADDY_CERT_DIR}/${MAIL_HOSTNAME}/${MAIL_HOSTNAME}.crt"
ISSUED=0
for _ in $(seq 1 30); do
	if [[ -f "${CERT_PATH}" ]]; then ISSUED=1; break; fi
	sleep 3
done

if [[ ${ISSUED} -eq 1 ]]; then
	ok "Certificate issued: ${CERT_PATH}"
	openssl x509 -in "${CERT_PATH}" -noout -subject -enddate 2>/dev/null | sed 's/^/  /'
else
	warn "No certificate yet at ${CERT_PATH}"
	warn "Usually means ${MAIL_HOSTNAME} does not resolve to this server yet (A record)."
	warn "Fix DNS, then: sudo systemctl reload caddy && sudo ./scripts/04-deploy-certs.sh"
fi

# ---- Local end-to-end check -------------------------------------------------
# Must be a real 200. A bare `curl -f` treats a 301 as success and would hide a
# redirect loop (mailcow's HTTP port redirects to HTTPS).
CODE="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 15 --max-redirs 5 \
	--resolve "${MAIL_HOSTNAME}:443:127.0.0.1" "https://${MAIL_HOSTNAME}/" 2>/dev/null || true)"
if [[ "${CODE}" == "200" ]]; then
	ok "https://${MAIL_HOSTNAME}/ returns 200 through Caddy"
elif [[ "${CODE}" == "000" || -z "${CODE}" ]]; then
	warn "https://${MAIL_HOSTNAME}/ not answering — is mailcow running? (scripts/02-install-mailcow.sh)"
else
	warn "https://${MAIL_HOSTNAME}/ returned HTTP ${CODE} (expected 200)"
	warn "A 301 here usually means Caddy is proxying mailcow's HTTP port, which redirects."
fi

hr
ok "Caddy configured. Next: sudo ./scripts/04-deploy-certs.sh"
hr
