# Install

Order matters. The A record must exist before Caddy can issue a certificate.

```
0. preflight  →  1. bootstrap  →  2. DNS A record  →  3. install mailcow
   →  4. Caddy   →  5. deploy certs  →  6. domain+DKIM in UI  →  7. rest of DNS
   →  8. PTR     →  9. verify
```

All scripts live in `scripts/` and are idempotent unless stated otherwise.

---

## 0 — Preflight (read-only)

```bash
sudo ./scripts/00-preflight.sh
```

Confirms RAM/disk/swap, Docker, **port 25 egress**, free ports, DNS state, PTR,
and blocklist reputation. Changes nothing.

---

## 1 — Bootstrap the host

```bash
sudo ./scripts/01-bootstrap-host.sh
```

- installs `git jq dnsutils openssl curl ufw cron`
- sets hostname to `mail.aipalassist.com` (and fixes `/etc/hosts`)
- creates a **2 GiB swapfile** (host had none)
- adds UFW `allow` rules for 25/465/587/143/993/110/995/4190
- checks NTP

It does **not** disable UFW and does not touch Caddy.

---

## 2 — DNS: the A record (only)

Create just this one first so TLS issuance can succeed:

| Type | Name | Value |
| --- | --- | --- |
| `A` | `mail` | `<your-vps-ip>` |

Confirm before moving on:

```bash
dig +short A mail.aipalassist.com @1.1.1.1   # → <your-vps-ip>
```

Full DNS guidance: [02-dns-godaddy.md](02-dns-godaddy.md). The remaining records
(SPF/DKIM/DMARC/MX) come after Mailcow has generated its DKIM key.

---

## 3 — Install mailcow

```bash
sudo ./scripts/02-install-mailcow.sh
```

What it does:

1. `git clone --depth 1 https://github.com/mailcow/mailcow-dockerized /opt/mailcow-dockerized`
2. `ln -sfn mailcow.conf .env` (generate_config refuses to run without it)
3. runs `generate_config.sh` **non-interactively** via
   `SKIP_BRANCH=y MAILCOW_BRANCH=master SKIP_CLAMD=n MAILCOW_HOSTNAME=… MAILCOW_TZ=Europe/Paris`
4. rewrites the keys it cares about in `mailcow.conf`:

   ```conf
   MAILCOW_HOSTNAME=mail.aipalassist.com
   ADDITIONAL_SERVER_NAMES=autodiscover.aipalassist.com,autoconfig.aipalassist.com
   HTTP_BIND=127.0.0.1
   HTTP_PORT=8080
   HTTPS_BIND=127.0.0.1
   HTTPS_PORT=8443
   SKIP_LETS_ENCRYPT=y
   ENABLE_SSL_SNI=n
   SKIP_CLAMD=n
   SKIP_FTS=n
   ```

5. `docker compose pull && docker compose up -d`

`SKIP_LETS_ENCRYPT=y` is essential: **Caddy** is the ACME client here. If Mailcow
tried to do HTTP-01 as well it would lose the race for port 80 and fail.

Nothing is publicly reachable yet — Mailcow listens on loopback only.

---

## 4 — Reverse proxy through Caddy

```bash
sudo ./scripts/03-caddy-setup.sh
```

This edits `/etc/caddy/Caddyfile` **carefully**:

1. backs it up to `Caddyfile.bak.<UTC timestamp>`
2. strips any previous managed block (between the `# >>> aipal-mail-server` markers)
3. appends a block serving `mail.` + `autodiscover.` + `autoconfig.` that
   `reverse_proxy`s to **`https://127.0.0.1:8443`** with
   `header_up Host {host}` and `transport http { tls … }`.
   It must be the **HTTPS** port: Mailcow's nginx answers anything on `HTTP_PORT`
   with an unconditional `301` to HTTPS, so proxying `8080` loops forever.
4. **validates** with the service env loaded —
   `env <contents of /etc/caddy/status-auth.env> caddy validate …`
5. on invalid config: **restores the backup and reloads nothing** (your other
   sites are never at risk)
6. on valid config: `systemctl reload caddy`
7. waits up to 90 s for Caddy to obtain the certificate

Verify the block:

```bash
sudo tail -n 30 /etc/caddy/Caddyfile
sudo systemctl status caddy --no-pager
```

---

## 5 — Share the certificate with the mail services

Web TLS is done by Caddy, but **SMTP/IMAP (465/587/993) also need a cert**, and
Mailcow's own ACME is disabled. This step copies Caddy's Let's Encrypt cert into
Mailcow's SSL directory and restarts the three services that read it.

```bash
sudo ./scripts/04-deploy-certs.sh
```

It is `md5`-aware — it only restarts containers when the cert actually changed —
and installs an **hourly cron** so renewals propagate automatically. That is the
maintenance requirement of the Caddy-fronted setup: Caddy renews, this job syncs.

---

## 6 — Add the domain and a mailbox in the UI

Open the **admin** login (not the root mailbox login) and log in with the
defaults:

```
https://mail.aipalassist.com/admin/
admin / <strong-password>
```

> The root page `/` is the **mailbox** (email address) login. Logging in there as
> `admin` always fails — see
> [05-troubleshooting.md](05-troubleshooting.md#login-failed-with-admin--<strong-password>-or-any-admin-password).

**Change that password immediately.**

Then:

1. **Configuration → Mail Setup → Domains → Add domain**
   - Domain: `aipalassist.com`
   - DKIM: enable it (Mailcow generates the key)
2. Copy the DKIM key it shows (or read it from `sudo ./scripts/05-dns-records.sh`)
3. **Mailboxes → Add mailbox** for `info@`, `steve@`, `dmarc@`, …

With an API key (`Configuration → API`, put it in `.env`) you can script it:

```bash
./scripts/06-create-mailbox.sh info 'a-strong-password' 3072
```

Recommended first set:

| Mailbox | Purpose |
| --- | --- |
| `steve@` | personal / primary |
| `info@` | general enquiries |
| `support@` | alias → `info@` (aliases cost no quota) |
| `dmarc@` | receives DMARC aggregate reports (`rua=`) |

Prefer **aliases** over mailboxes where possible — same deliverability, less
quota and RAM.

---

## 7 — Remaining DNS records

Now that DKIM exists:

```bash
sudo ./scripts/05-dns-records.sh
```

Enter MX, SPF, DKIM and DMARC in GoDaddy as printed. See
[02-dns-godaddy.md](02-dns-godaddy.md) for the table and the DMARC edit nuance.

---

## 8 — Reverse DNS

hPanel → VPS → Network → IPv4 → Reverse DNS → `mail.aipalassist.com`.
Details in [02-dns-godaddy.md](02-dns-godaddy.md#reverse-dns-ptr--do-this-in-hostinger-hpanel).

---

## 9 — Verify

```bash
./scripts/07-verify.sh
```

Checks A/MX/SPF/DKIM/DMARC/PTR, outbound 25, inbound 25/465/587/143/993, TLS
certificate names on each mail port, the web UI, and container health.

Then the real test — deliverability:

1. Open <https://www.mail-tester.com/>
2. Send an email **from** `steve@aipalassist.com` to the address it shows
3. Go **back to the page** and click "Check your score" — target **10/10**

> **mail-tester does not email you the score.** The result is rendered on the web
> page for the unique address you were given (`test-xxxx@srv1.mail-tester.com`).
> If you close the tab before checking, the result for that address is lost — get
> a new one and resend.

For a scriptable check that *does* reply with a report, send to
`check-auth@verifier.port25.com` and read the reply from the mailbox:

```bash
docker exec $(docker ps -qaf name=dovecot-mailcow) \
  doveadm fetch -u info@aipalassist.com "text" mailbox INBOX | grep -a "SPF check"
```

If mail-tester flags something, see
[05-troubleshooting.md](05-troubleshooting.md).

---

## Client settings

| Protocol | Host | Port | Security |
| --- | --- | --- | --- |
| IMAP | `mail.aipalassist.com` | `993` | SSL/TLS |
| SMTP submission | `mail.aipalassist.com` | `587` | STARTTLS |
| SMTP (alt) | `mail.aipalassist.com` | `465` | SSL/TLS |
| Webmail | <https://mail.aipalassist.com/SOGo/> | — | — |
| Admin | <https://mail.aipalassist.com> | — | — |

Username is the **full address** (`steve@aipalassist.com`), not the local part.

## Rollback

```bash
cd /opt/mailcow-dockerized && docker compose down      # stop mail (keeps data)
sudo cp /etc/caddy/Caddyfile.bak.<ts> /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

DNS records can be deleted; Mailcow data lives in
`/opt/mailcow-dockerized/data` (back it up — see [04-operations.md](04-operations.md)).
