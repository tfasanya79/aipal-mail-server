#!/usr/bin/env bash
# Clone, configure and start mailcow: dockerized, bound to loopback so that
# the pre-existing Caddy instance keeps public 80/443.
#   sudo ./scripts/02-install-mailcow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_root

if docker compose version >/dev/null 2>&1; then
	COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
	COMPOSE=(docker-compose)
else
	die "Neither 'docker compose' nor 'docker-compose' is available"
fi

hr; log "Installing mailcow into ${MAILCOW_DIR}"; hr

docker_ok || die "Docker daemon not reachable"

IP="$(detect_public_ip)"
[[ -n "${IP}" ]] || die "Could not determine public IPv4"

# DNS must be in place, otherwise generate_config asks for confirmation and
# Caddy cannot obtain a certificate for ${MAIL_HOSTNAME}.
MAIL_A="$(resolve_a "${MAIL_HOSTNAME}")"
if [[ "${MAIL_A}" != "${IP}" ]]; then
	warn "${MAIL_HOSTNAME} resolves to '${MAIL_A:-<none>}', expected ${IP}"
	warn "Set the A record first (docs/02-dns-godaddy.md). Continuing in 10s; Ctrl-C to abort."
	sleep 10
fi

# ---- Checkout ---------------------------------------------------------------
if [[ -d "${MAILCOW_DIR}/.git" ]]; then
	ok "mailcow checkout already present — reusing"
else
	log "Cloning mailcow into ${MAILCOW_DIR}"
	git clone --depth 1 https://github.com/mailcow/mailcow-dockerized "${MAILCOW_DIR}"
	ok "Cloned $(git -C "${MAILCOW_DIR}" log -1 --format='%h %ad' --date=short)"
fi

# ---- Configuration ----------------------------------------------------------
cd "${MAILCOW_DIR}" || die "Cannot cd into ${MAILCOW_DIR}"

if [[ -f mailcow.conf ]]; then
	ok "mailcow.conf exists — skipping generate_config (overrides will still apply)"
else
	log "Generating mailcow.conf non-interactively"
	# generate_config.sh requires the .env symlink to exist beforehand
	ln -sfn mailcow.conf .env

	# Env vars skip the hostname/timezone/branch prompts; the piped 'y' answers
	# the config-exists and "hostname does not resolve — proceed?" prompts.
	if ! printf 'y\ny\ny\n' | env \
		SKIP_BRANCH=y \
		MAILCOW_BRANCH=master \
		SKIP_CLAMD=n \
		MAILCOW_HOSTNAME="${MAIL_HOSTNAME}" \
		MAILCOW_TZ="${MAILCOW_TZ}" \
		./generate_config.sh; then
		die "generate_config.sh failed — run it manually: cd ${MAILCOW_DIR} && ./generate_config.sh"
	fi
	ok "mailcow.conf generated"
fi

# ---- Apply AiPal overrides (idempotent) -------------------------------------
log "Applying AiPal overrides"
set_conf MAILCOW_HOSTNAME            "${MAIL_HOSTNAME}"
set_conf ADDITIONAL_SERVER_NAMES     "${ADDITIONAL_SERVER_NAMES}"
set_conf HTTP_BIND                   "${MAILCOW_HTTP_BIND}"
set_conf HTTP_PORT                   "${MAILCOW_HTTP_PORT}"
set_conf HTTPS_BIND                  "${MAILCOW_HTTPS_BIND}"
set_conf HTTPS_PORT                  "${MAILCOW_HTTPS_PORT}"
set_conf SKIP_LETS_ENCRYPT           "y"
set_conf ENABLE_SSL_SNI              "n"
set_conf SKIP_CLAMD                  "n"
set_conf SKIP_FTS                    "n"
set_conf MAILCOW_TZ                  "${MAILCOW_TZ}"
grep -E '^(MAILCOW_HOSTNAME|HTTP_BIND|HTTP_PORT|HTTPS_BIND|HTTPS_PORT|SKIP_LETS_ENCRYPT|ADDITIONAL_SERVER_NAMES)=' mailcow.conf | sed 's/^/  /'
ok "Overrides applied"

# ---- Prefer IPv4 for outbound ----------------------------------------------
# Postfix defaults to smtp_address_preference=any and will happily send over
# IPv6. On this host SPF is `mx` (i.e. the IPv4 A record) and Hostinger exposes
# no IPv6 PTR (the API rejects it: VPS:2004), so IPv6 sends score SPF softfail.
# extra.cf is appended to main.cf at container start, so later values win.
PF_EXTRA="${MAILCOW_DIR}/data/conf/postfix/extra.cf"
mkdir -p "$(dirname "${PF_EXTRA}")"
touch "${PF_EXTRA}"
if ! grep -q '^smtp_address_preference' "${PF_EXTRA}"; then
	printf '%s\n' \
		'# Prefer IPv4: SPF(mx) and the PTR are IPv4-aligned; no IPv6 PTR available' \
		'smtp_address_preference = ipv4' >> "${PF_EXTRA}"
	ok "Set smtp_address_preference = ipv4 in postfix extra.cf"
fi

# ---- Start ------------------------------------------------------------------
log "Pulling images (this takes a few minutes)"
"${COMPOSE[@]}" pull 2>&1 | tail -n 5

log "Starting mailcow"
"${COMPOSE[@]}" up -d 2>&1 | tail -n 20

log "Waiting for services to settle (up to 120s)"
for _ in $(seq 1 24); do
	if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${MAILCOW_HTTP_PORT}/" 2>/dev/null; then
		ok "mailcow nginx responding on 127.0.0.1:${MAILCOW_HTTP_PORT}"
		break
	fi
	sleep 5
done

echo
"${COMPOSE[@]}" ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null \
	|| "${COMPOSE[@]}" ps
hr
ok "mailcow is installed. It is bound to loopback only — nothing is public yet."
log "Next steps:"
echo "  1. sudo ./scripts/03-caddy-setup.sh     # proxy ${MAIL_HOSTNAME} via Caddy (issues TLS)"
echo "  2. sudo ./scripts/04-deploy-certs.sh    # share Caddy's cert with postfix/dovecot"
echo "  3. Add domain + mailboxes in the UI: https://${MAIL_HOSTNAME}"
echo "     (default login admin / moohoo — change immediately)"
echo "  4. sudo ./scripts/05-dns-records.sh     # emit the GoDaddy records incl. DKIM"
hr
