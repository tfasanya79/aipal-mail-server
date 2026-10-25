#!/usr/bin/env bash
# Create a mailbox in mailcow via its REST API.
#   ./scripts/06-create-mailbox.sh info            # prompts for a password
#   ./scripts/06-create-mailbox.sh steve 'S3cret!' 3072
# Requires MAILCOW_API_KEY in .env (mailcow UI -> Configuration -> API).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

LOCALPART="${1:-}"
PASSWORD="${2:-}"
QUOTA="${3:-3072}"

[[ -n "${LOCALPART}" ]] || die "Usage: $0 <local-part> [password] [quota-mb]"
[[ -n "${MAILCOW_API_KEY:-}" ]] || die "MAILCOW_API_KEY is empty — set it in .env (ui -> Configuration -> API)"

if [[ -z "${PASSWORD}" ]]; then
	read -r -s -p "Password for ${LOCALPART}@${DOMAIN}: " PASSWORD; echo
	[[ -n "${PASSWORD}" ]] || die "Password required"
fi

command -v jq >/dev/null 2>&1 || die "jq is required (apt-get install -y jq)"

# A readable display name derived from the local part
DISPLAY_NAME="$(echo "${LOCALPART}" | sed 's/[._-]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')"

PAYLOAD="$(jq -n \
	--arg lp "${LOCALPART}" \
	--arg dom "${DOMAIN}" \
	--arg name "${DISPLAY_NAME}" \
	--arg quota "${QUOTA}" \
	--arg pw "${PASSWORD}" \
	'{local_part:$lp, domain:$dom, name:$name, quota:$quota,
	  password:$pw, password2:$pw,
	  active:"1", force_pw_update:"0",
	  tls_enforce_in:"0", tls_enforce_out:"0"}')"

log "Creating ${LOCALPART}@${DOMAIN} (quota ${QUOTA} MiB)"
RESP="$(curl -sS -X POST "${MAILCOW_API_URL}/add/mailbox" \
	-H "X-API-Key: ${MAILCOW_API_KEY}" \
	-H 'Content-Type: application/json' \
	-d "${PAYLOAD}")"

if echo "${RESP}" | jq -e 'if type=="array" then .[0].type=="success" else .type=="success" end' >/dev/null 2>&1; then
	ok "Mailbox created: ${LOCALPART}@${DOMAIN}"
else
	fail "API said: ${RESP}"
	exit 1
fi
