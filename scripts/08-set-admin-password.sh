#!/usr/bin/env bash
# Reset the mailcow admin password from the host — no UI, no API key needed.
#
#   sudo ./scripts/set-admin-password.sh 'MyNewStrongPassword'
#   sudo ./scripts/set-admin-password.sh          # generates a random one
#
# Uses mailcow's own hashing scheme ({SSHA256} = base64(sha256(pw+salt)+salt),
# salt = 16 hex chars), so the UI verifies it exactly like a normal password.
# Also re-activates the account, which undoes a lockout.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_root

ADMIN_USER="${ADMIN_USER:-admin}"
PASSWORD="${1:-}"
GENERATED=0

CONF="${MAILCOW_DIR}/mailcow.conf"
[[ -f "${CONF}" ]] || die "mailcow.conf not found at ${CONF} (is mailcow installed?)"

PHP_C="$(docker ps -qaf 'name=php-fpm-mailcow')"
MY_C="$(docker ps -qaf 'name=mysql-mailcow')"
[[ -n "${PHP_C}" ]] || die "php-fpm-mailcow container is not running"
[[ -n "${MY_C}"  ]] || die "mysql-mailcow container is not running"

hr; log "Resetting mailcow admin password for '${ADMIN_USER}'"; hr

if [[ -z "${PASSWORD}" ]]; then
	PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
	GENERATED=1
fi
[[ ${#PASSWORD} -ge 8 ]] || die "Password must be at least 8 characters"

# ---- Generate a mailcow-compatible hash -------------------------------------
# Password travels via env, never on the container command line.
HASH="$(docker exec -e MC_PW="${PASSWORD}" "${PHP_C}" php -r '
	$p = getenv("MC_PW");
	$s = bin2hex(random_bytes(8));
	echo "{SSHA256}" . base64_encode(hash("sha256", $p . $s, true) . $s);
')"
[[ -n "${HASH}" ]] || die "Failed to generate password hash"
ok "Generated mailcow {SSHA256} hash (length ${#HASH})"

# ---- Update the database ----------------------------------------------------
DBPASS="$(sed -n 's/^DBPASS=//p' "${CONF}" | tail -1)"
DBUSER="$(sed -n 's/^DBUSER=//p' "${CONF}" | tail -1)"; : "${DBUSER:=mailcow}"
DBNAME="$(sed -n 's/^DBNAME=//p' "${CONF}" | tail -1)"; : "${DBNAME:=mailcow}"

docker exec -e MYSQL_PWD="${DBPASS}" "${MY_C}" \
	mysql -u "${DBUSER}" "${DBNAME}" \
	-e "UPDATE admin SET password='${HASH}', active=1, modified=NOW() WHERE username='${ADMIN_USER}';" \
	|| die "Database update failed"

ROWS="$(docker exec -e MYSQL_PWD="${DBPASS}" "${MY_C}" \
	mysql -u "${DBUSER}" -N -B "${DBNAME}" \
	-e "SELECT COUNT(*) FROM admin WHERE username='${ADMIN_USER}' AND active=1;" 2>/dev/null)"

if [[ "${ROWS}" != "1" ]]; then
	die "Update did not take effect (admin row missing or inactive)"
fi
ok "Admin '${ADMIN_USER}' is active and password updated"

# ---- Prove the new hash verifies -------------------------------------------
VERIFIED="$(docker exec -e MC_PW="${PASSWORD}" -e MC_HASH="${HASH}" "${PHP_C}" php -r '
	$h = getenv("MC_HASH"); $p = getenv("MC_PW");
	$raw = base64_decode(substr($h, 9));
	$digest = substr($raw, 0, 32);
	$salt   = substr($raw, 32);
	echo hash("sha256", $p . $salt, true) === $digest ? "OK" : "FAIL";
')"

if [[ "${VERIFIED}" == "OK" ]]; then
	ok "Hash verified against the new password"
else
	die "Hash verification failed — do not trust this password"
fi

echo
if [[ ${GENERATED} -eq 1 ]]; then
	log "Temporary password for '${ADMIN_USER}':"
	printf '\n    %s\n\n' "${PASSWORD}"
	warn "Change it immediately: UI -> Configuration -> Admins (or Account)."
fi
log "Log in at https://${MAIL_HOSTNAME}/ using username '${ADMIN_USER}'"
hr
