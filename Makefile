# =============================================================================
# AiPal Mail Server — task runner
# All targets run on the target host (Ubuntu 24.04). Most need root.
# =============================================================================

SHELL := /bin/bash
HOST  ?= aipal-vm2

.PHONY: help preflight bootstrap install caddy certs dns verify mailbox admin-pass \
        ssh-preflight ssh-bootstrap ssh-install ssh-all all

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;34m%-16s\033[0m %s\n", $$1, $$2}'

preflight: ## Read-only environment report
	sudo ./scripts/00-preflight.sh

bootstrap: ## Packages, hostname, swap, firewall mail ports
	sudo ./scripts/01-bootstrap-host.sh

install: ## Clone + configure + start mailcow (loopback only)
	sudo ./scripts/02-install-mailcow.sh

caddy: ## Proxy MAIL_HOSTNAME through the existing Caddy (issues TLS)
	sudo ./scripts/03-caddy-setup.sh

certs: ## Share Caddy's cert with postfix/dovecot + hourly cron
	sudo ./scripts/04-deploy-certs.sh

dns: ## Print the GoDaddy records incl. DKIM
	sudo ./scripts/05-dns-records.sh

verify: ## End-to-end DNS/TLS/port/container checks
	./scripts/07-verify.sh

mailbox: ## Create a mailbox: make mailbox LP=info [PW=secret] [QUOTA=3072]
	./scripts/06-create-mailbox.sh "$(LP)" "$(PW)" "$(QUOTA)"

admin-pass: ## Reset admin password: make admin-pass [PW='newpass']
	sudo ./scripts/08-set-admin-password.sh "$(PW)"

# ---- convenience: run over SSH from your workstation -----------------------
ssh-preflight: ## Run preflight on $(HOST)
	ssh $(HOST) 'bash -s' < scripts/00-preflight.sh

ssh-bootstrap: ## Run bootstrap on $(HOST)
	ssh $(HOST) 'sudo bash -s' < scripts/01-bootstrap-host.sh

ssh-install: ## Run mailcow install on $(HOST)
	ssh $(HOST) 'sudo bash -s' < scripts/02-install-mailcow.sh

ssh-all: ssh-bootstrap ssh-install ## Bootstrap + install over SSH
	@echo "Now run: make ssh-caddy (add target) or execute scripts 03/04 on the host"
