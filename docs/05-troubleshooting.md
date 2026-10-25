# Troubleshooting

Symptoms first, then cause. `sudo ./scripts/00-preflight.sh` and
`./scripts/07-verify.sh` cover most diagnostics.

---

## Admin login

### "Login failed" with `admin` / `moohoo`

The default account **is** created as `admin` / `moohoo` — mailcow inserts a
hardcoded `{SSHA256}` hash at first boot. If that fails, the UI received a
different password than you think. Usual causes:

- **Browser password manager autofilled a stale password** over the field. The
  autofill dropdown is a strong tell. Use a private/incognito window, or clear
  the saved entry for this site, and type the password manually.
- **Using the "User Login" (email address) form** with a bare `admin`. That form
  wants a mailbox address; the admin login is the link at the bottom
  ("Log in as admin") or just submit `admin` as the username.
- A trailing space pasted along with the password.

Confirm what the database actually holds before assuming it's broken:

```bash
CONF=/opt/mailcow-dockerized/mailcow.conf
DP=$(sudo sed -n 's/^DBPASS=//p' $CONF); DU=$(sudo sed -n 's/^DBUSER=//p' $CONF); DN=$(sudo sed -n 's/^DBNAME=//p' $CONF)
M=$(docker ps -qaf name=mysql-mailcow)
docker exec -e MYSQL_PWD="$DP" "$M" mysql -u "$DU" -N -B "$DN" \
  -e "select username, active, superadmin, password from admin;"
```

A hash starting `{SSHA256}K8eVJ6YsZbQCfuJvSUbaQ...` is mailcow's built-in
`moohoo` default, untouched.

### Reset the admin password from the host

No UI and no API key required — it writes a properly-formatted `{SSHA256}` hash
and proves it verifies:

```bash
sudo ./scripts/08-set-admin-password.sh              # generate a random password
sudo ./scripts/08-set-admin-password.sh 'MyNewPass!' # set a specific one
# or:
make admin-pass PW='MyNewPass!'
```

It also sets `active=1`, which clears a lockout. Change the resulting password in
the UI immediately (Configuration → Admins).

### Locked out after repeated failures

mailcow's fail2ban (the `netfilter` container) can ban the client IP. The ban is
temporary, but you can check and clear it:

```bash
docker exec $(docker ps -qaf name=netfilter-mailcow) fail2ban-client status
docker exec $(docker ps -qaf name=netfilter-mailcow) fail2ban-client set mailcow unbanip <YOUR_IP>
```

`scripts/08-set-admin-password.sh` re-activates the account but does not clear an
IP ban.

---

## Web UI

### `https://mail.aipalassist.com` → redirect loop (`ERR_TOO_MANY_REDIRECTS`)

Caddy is proxying the **plain-HTTP** port. Mailcow's nginx (`location /`) answers
every request on `HTTP_PORT` with `return 301 https://$host...`, so HTTP → 301 →
HTTPS → Caddy → HTTP → 301…

Fix: proxy `https://127.0.0.1:8443` (the TLS port), which is what
`scripts/03-caddy-setup.sh` writes. Check the managed block:

```bash
sudo sed -n '/>>> aipal-mail-server/,/<<< aipal-mail-server/p' /etc/caddy/Caddyfile
# must contain: reverse_proxy https://127.0.0.1:8443
```

Then `sudo ./scripts/03-caddy-setup.sh` and confirm
`curl -sL -o /dev/null -w '%{http_code} %{num_redirects}\n' https://mail.aipalassist.com/`
prints `200 0`.

### `https://mail.aipalassist.com` → 502 Bad Gateway

Caddy is up but Mailcow's nginx isn't answering on `127.0.0.1:8443`.

```bash
cd /opt/mailcow-dockerized
docker compose ps                        # is nginx-mailcow up?
docker logs --tail 50 $(docker ps -qf name=nginx-mailcow)
grep -E '^(HTTP_BIND|HTTP_PORT|HTTPS_BIND|HTTPS_PORT)=' mailcow.conf
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/
```

Common causes: `HTTPS_PORT` not `8443`, container crashed, or `docker compose up -d`
was not re-run after editing `mailcow.conf`. Editing that file **requires**
`docker compose up -d` to recreate the containers.

### `https://mail.aipalassist.com` → Caddy 404 / wrong site

`ADDITIONAL_SERVER_NAMES` doesn't include the hostname, so Mailcow's nginx
answers as the wrong vhost.

```bash
grep ADDITIONAL_SERVER_NAMES /opt/mailcow-dockerized/mailcow.conf
# must be: ADDITIONAL_SERVER_NAMES=autodiscover.aipalassist.com,autoconfig.aipalassist.com
cd /opt/mailcow-dockerized && docker compose up -d
```

### Certificate not issued by Caddy

```bash
dig +short A mail.aipalassist.com @1.1.1.1   # must equal the server IP
sudo journalctl -u caddy --since '15 min ago' | grep -iE 'acme|error|certificate'
sudo ls -l /var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/mail.aipalassist.com/
```

Let's Encrypt rate limits are strict (5 duplicate certs/week). If you're stuck,
**fix DNS first**, then `sudo systemctl reload caddy`. Do not hammer retries.

### Mailcow's own ACME keeps failing

It shouldn't be running. Confirm:

```bash
grep SKIP_LETS_ENCRYPT /opt/mailcow-dockerized/mailcow.conf   # → y
docker logs --tail 30 $(docker ps -qf name=acme-mailcow)
```

If it's `n`, set it to `y`, `docker compose up -d`, and rely on
`scripts/04-deploy-certs.sh`.

---

## SMTP / IMAP

### Clients can't connect on 465 / 587 / 993

```bash
# from inside the host
for p in 25 465 587 993; do timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" \
  && echo "$p ok" || echo "$p dead"; done

# from outside (your laptop)
nc -vz mail.aipalassist.com 993
```

If local ports are alive but external ones aren't, it's the firewall:

```bash
sudo ufw status verbose                      # mail ports allowed?
sudo iptables -S DOCKER-USER | head
```

This host keeps UFW active with `deny (routed)`. Docker normally inserts its own
`FORWARD`/`DOCKER-USER` rules ahead of that, which is why published container
ports work. If you deliberately tightened `DOCKER-USER`, loosen it for the mail
ports.

### `535 5.7.8 authentication failed`

- Username must be the **full address** (`steve@aipalassist.com`), not `steve`.
- Use IMAP `993`/`SSL` and SMTP `587`/`STARTTLS` (or `465`/`SSL`).
- Check the mailbox isn't disabled and the domain isn't deactivated in the UI.

---

## Deliverability

### Mail lands in spam at Gmail / Outlook

Work through in order — do not skip:

```bash
dig +short MX   aipalassist.com                    @1.1.1.1
dig +short TXT  aipalassist.com                    @1.1.1.1   # exactly ONE spf1
dig +short TXT  dkim._domainkey.aipalassist.com    @1.1.1.1
dig +short TXT  _dmarc.aipalassist.com             @1.1.1.1
dig +short -x   187.55.230.139                     @1.1.1.1   # must be mail.aipalassist.com
```

Then:

1. **PTR mismatch** — the most common single cause. Fix in hPanel.
2. **Two SPF records** — instant SPF failure. Merge into one.
3. **DMARC too strict too early** — if you're at `p=quarantine` while DKIM was
   ever broken, reputation suffers. Go back to `p=none` while you debug.
4. **DKIM key not matching** — Mailcow shows the key; regenerate the domain's
   DKIM in the UI and re-paste the TXT record. Long base64 values are easy to
   truncate: verify length matches what the UI shows.
5. **No warm-up** — a new domain has no history. See
   [04-operations.md](04-operations.md#deliverability-warm-up).
6. **Content** — links, image-heavy HTML, and "free/urgent" wording all count
   against you on a fresh domain. Send plain text for the first week.

Test with <https://www.mail-tester.com/> (target 10/10) and
<https://check.spamhaus.org/>.

### Mail to a specific domain gets rejected

Read the actual bounce in the queue:

```bash
docker exec -it $(docker ps -qf name=postfix-mailcow) postqueue -p
docker logs --tail 200 $(docker ps -qf name=postfix-mailcow) | grep -iE 'reject|550|554|blocked'
```

Typical: `550 5.7.1 ... blocked using Spamhaus` (IP reputation — check the blocklist
and request delisting), or `554 ... no PTR record`.

### Outbound mail is throttled

Expected. Hostinger rate-limits egress to roughly **5 messages/minute**. For
business correspondence this is invisible. For anything bulkier, add a smart-host
relay:

```
Mailcow UI → Configuration → Routing → Relayhosts → Add
```

SMTP2GO's free tier (1 000/month) is the usual choice. This preserves everything
else — Mailcow still receives and stores mail; only outbound leaves via the relay.

---

## Host / Docker

### Containers keep restarting

```bash
docker compose ps
docker logs --tail 100 $(docker ps -aqf name=<service>)
free -h; df -h /
dmesg | tail -30 | grep -i oom
```

With 32 GiB this should never be OOM. More likely: a port collision (something
already on 25/465/587/993), or a corrupted `mailcow.conf`.

### After a Caddy change, other sites broke

`scripts/03-caddy-setup.sh` validates before reloading and rolls back on failure,
so this is unlikely — but recovery is trivial:

```bash
ls -t /etc/caddy/Caddyfile.bak.* | head
sudo cp /etc/caddy/Caddyfile.bak.<timestamp> /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

### `caddy validate` complains about username/password

Not a real error. The Caddyfile uses `{env.STATUS_AUTH_USER}` /
`{env.STATUS_AUTH_HASH}` from `/etc/caddy/status-auth.env`. Validation must load
that file, which `03-caddy-setup.sh` does. Running `caddy validate` bare gives a
false failure.

### DKIM cron / cert sync stopped running

```bash
crontab -l | grep deploy-certs
sudo tail -50 /var/log/aipal-deploy-certs.log
sudo ./scripts/04-deploy-certs.sh
```

---

## DNS

### Changes aren't taking effect

- GoDaddy minimum TTL is 1 hour; negative caching can add more.
- Query an external resolver, not the local one:
  `dig +short MX aipalassist.com @1.1.1.1`
- Two `TXT` records for `@` (one SPF, one something else) is fine — two `spf1`
  records is **not**.

### I can't find where to set PTR

hPanel → VPS → server → **Network** / **IPv4** → Reverse DNS. If your plan's
panel lacks the field, open a ticket: "Please set the PTR for 187.55.230.139 to
mail.aipalassist.com." It's a standard request.

---

## Nuclear option (start the mail stack over)

```bash
cd /opt/mailcow-dockerized
docker compose down            # keeps data/
sudo rm -f mailcow.conf .env   # DESTRUCTIVE of config, keeps mail
sudo ./scripts/02-install-mailcow.sh
```

Your mail, DKIM keys and accounts live in `data/` and survive this.
Take a backup first if there's anything you care about.
