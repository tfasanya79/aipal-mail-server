#!/usr/bin/env bash
# One-time host preparation: packages, hostname, swap, firewall ports.
# Idempotent — safe to re-run.
#   sudo ./scripts/01-bootstrap-host.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_root

MAIL_PORTS=(25 465 587 143 993 110 995 4190)

hr; log "Bootstrapping host for mailcow at ${MAIL_HOSTNAME}"; hr

# ---- Packages ---------------------------------------------------------------
log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	ca-certificates curl git jq dnsutils openssl ufw cron
ok "Packages installed"

if ! docker_ok; then
	warn "Docker is not runnable. Install Docker >= 24 before continuing:"
	echo "  curl -fsSL https://get.docker.com | sh"
	die "Docker missing/inactive"
fi
printf '  docker %s / compose %s\n' \
	"$(docker version --format '{{.Server.Version}}')" \
	"$(docker compose version --short 2>/dev/null || echo n/a)"

# ---- Hostname ---------------------------------------------------------------
log "Setting system hostname to ${MAIL_HOSTNAME}"
hostnamectl set-hostname "${MAIL_HOSTNAME}"

# Ensure the FQDN resolves locally and before the hstgr.cloud entry
if grep -qE "^127\.0\.1\.1" /etc/hosts; then
	sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${MAIL_HOSTNAME} ${MAIL_HOSTNAME%%.*}/" /etc/hosts
else
	printf '127.0.1.1\t%s %s\n' "${MAIL_HOSTNAME}" "${MAIL_HOSTNAME%%.*}" >> /etc/hosts
fi
[[ "$(hostname -f)" == "${MAIL_HOSTNAME}" ]] \
	&& ok "hostname -f => ${MAIL_HOSTNAME}" \
	|| warn "hostname -f => $(hostname -f) (expected ${MAIL_HOSTNAME})"

# ---- Swap -------------------------------------------------------------------
SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
if [[ ${SWAP_MB} -lt 512 ]]; then
	log "Creating 2 GiB swapfile (mailcow recommends >= 1 GiB)"
	if [[ ! -f /swapfile ]]; then
		fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
		chmod 600 /swapfile
		mkswap /swapfile >/dev/null
	fi
	swapon /swapfile 2>/dev/null || true
	grep -qE '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	ok "Swap enabled: $(awk '/SwapTotal/{printf "%d MiB", $2/1024}' /proc/meminfo)"
else
	ok "Swap already present (${SWAP_MB} MiB)"
fi

# ---- Firewall ---------------------------------------------------------------
# NOTE: UFW is already active on this host and protects SSH + Caddy's 80/443.
# Mailcow publishes its mail ports via Docker; we add UFW allows so host-level
# policy does not fight it. We deliberately do NOT flush or disable UFW here —
# doing so would risk the other sites on this box.
log "Adding UFW allow rules for mail ports"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
	for p in "${MAIL_PORTS[@]}"; do
		ufw allow "${p}/tcp" >/dev/null 2>&1 || true
	done
	ok "UFW: allowed ${MAIL_PORTS[*]}"
	warn "Do NOT run 'ufw --force reset'; it would drop the rules for your other sites."
else
	warn "UFW not active — skipping (Docker manages port publishing regardless)"
fi

# ---- Kernel/network hygiene -------------------------------------------------
log "Checking time sync"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
	ok "NTP synchronized"
else
	warn "NTP not synchronized — TLS/TOTP may misbehave"
fi

hr
ok "Bootstrap complete. Next: docs/02-dns-godaddy.md (DNS must resolve before install)."
hr
