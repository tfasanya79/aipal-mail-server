# Operations

## Daily use

| Task | Where |
| --- | --- |
| Add/remove mailbox, alias, quota | <https://mail.aipalassist.com> → Mailboxes |
| Read mail via web | <https://mail.aipalassist.com/SOGo/> |
| Spam settings, quarantine | Mailcow UI → Configuration → Spamfilter |
| Admin API key | UI → Configuration → API |

Account types and what they cost:

| Type | Quota cost | Use for |
| --- | --- | --- |
| **Mailbox** | full quota | humans who need to read mail (`steve@`) |
| **Alias** | ~0 | role addresses that forward (`support@` → `info@`) |
| **Catch-all** | — | only if you accept spam risk |

Prefer aliases for `support@`, `sales@`, `billing@` unless someone must log in.

## Backups

Mailcow has a built-in backup and it is genuinely good:

```bash
cd /opt/mailcow-dockerized
sudo ./helper-scripts/backup_and_restore.sh backup all
```

Schedule it and **copy it off-host** — this host also runs other production apps,
and Hostinger's abuse team has a documented history of suspending accounts
without warning or backup access. Treat anything on this VPS as ephemeral.

```bash
# nightly at 03:17, then push off-site (rclone / restic / Backblaze B2)
crontab -e
17 3 * * * cd /opt/mailcow-dockerized && ./helper-scripts/backup_and_restore.sh backup all >> /var/log/mailcow-backup.log 2>&1
```

Restore (into the same or a new host):

```bash
sudo ./helper-scripts/backup_and_restore.sh restore
```

Data lives at `/opt/mailcow-dockerized/data/` — maildir, mysql, certs, DKIM keys.
That directory *is* your server. At minimum copy it off-host weekly.

## Updates

```bash
cd /opt/mailcow-dockerized
sudo ./update.sh
```

Mailcow is fast-moving; update monthly. The update preserves `mailcow.conf`. After
an update, re-run `sudo ./scripts/04-deploy-certs.sh` to confirm the cert sync
still works, and `./scripts/07-verify.sh`.

Caddy is separate:

```bash
sudo apt update && sudo apt install --only-upgrade caddy
sudo systemctl reload caddy
```

> This host runs **Caddy 2.6.2** (2022). It works, but consider a deliberate
> upgrade to a current 2.x during a maintenance window — it is not required for
> mail to function.

## Deliverability warm-up

This is the part people skip, then wonder why everything lands in spam.

**Why it matters here:** you have a brand-new domain and a datacenter IP. Gmail
and Outlook have no reputation history for either. A clean DNSBL and perfect
SPF/DKIM/DMARC are necessary but not sufficient — they prove you're *allowed* to
send, not that you're *trusted*.

Warm-up plan:

1. **Week 1** — own-mailbox only. Send 5–10 messages/day between
   `steve@aipalassist.com` and `info@aipalassist.com`. Reply to yourself.
   Mark messages "not spam" if they appear there.
2. **Week 1–2** — DMARC at `p=none`, read the aggregate reports sent to
   `dmarc@aipalassist.com`. Confirm SPF and DKIM both pass, aligned.
3. **Week 2–3** — real, wanted, low-volume mail to known contacts who will
   *open and reply*. Opens and replies are the strongest positive signal.
4. **Week 3+** — move DMARC to `p=quarantine`, then later `p=reject`.
5. Never send unsolicited bulk mail. Never send from `noreply@` expecting inbox
   placement. Never blast more than the ~5/min Hostinger egress limit.

Also: publish and keep `postmaster@` and `abuse@` reachable — they are looked up
by some receivers and their absence is a negative signal.

Optional but worth it once stable:

- **MTA-STS** — see `docs.mailcow.email/post_installation/setup-mta-sts/`
- **TLS-RPT** — add a `_smtp._tls` TXT record for TLS failure reporting

## Monitoring

```bash
# anything down?
docker ps --filter name=mailcow --format '{{.Names}}\t{{.Status}}'

# queue
docker exec -it $(docker ps -qf name=postfix-mailcow) postqueue -p

# mail log
docker logs --tail 100 $(docker ps -qf name=postfix-mailcow)

# rspamd
docker logs --tail 100 $(docker ps -qf name=rspamd-mailcow)

# watchdog status in UI
https://mail.aipalassist.com  (top bar shows unhealthy containers)
```

A simple external uptime check on `https://mail.aipalassist.com` plus a port-993
check covers most failure modes.

## Capacity

- 32 GiB RAM, 8 vCPU, ~332 GiB free disk — **vastly** over-spec for a handful of
  mailboxes. Mailcow idles around 3–4 GiB.
- Mail volume is capped by Hostinger's ~5 msg/min outbound limit, which you will
  never hit with business correspondence.
- Bandwidth cap is 32 TB/month; mail is negligible.

## Security checklist

- [ ] Changed the `admin / moohoo` password
- [ ] Enabled 2FA on the Mailcow admin account (UI → Configuration → Admin)
- [ ] Restrict admin UI by IP if convenient (Mailcow → Netfilter)
- [ ] No plaintext ports exposed: use 993/465/587 only, not 143/110
- [ ] UFW left enabled (80/443/22 + mail ports)
- [ ] Backups copied **off-host**
- [ ] Keep `SKIP_LETS_ENCRYPT=y` and the `04-deploy-certs.sh` cron in place

## Cost

| Item | Cost |
| --- | --- |
| Mailcow (AGPL) | $0 |
| Caddy / Let's Encrypt | $0 |
| GoDaddy DNS records | $0 |
| Outbound relay | **not needed** — port 25 is open |
| VPS | already paid (KVM 8) |
| **Total incremental** | **$0/month** |

The only real cost is your time and the ongoing patch/backup discipline.

## Comparison: when to stop self-hosting

Self-hosting wins while you're at this scale and enjoy it. Switch to a provider
if any of these become true:

- you need more than ~5 msgs/minute sustained (then add a relay first — cheaper)
- deliverability problems persist after a month of correct DNS + warm-up
- you can't commit to monthly updates and off-host backups
- the mailbox count grows past a few dozen with heavy shared-calendar/ActiveSync
  use (RAM and support burden rise non-linearly)

Cheap providers worth knowing: Zoho Mail (free tier, 1 domain), Migadu (flat,
unlimited mailboxes), MXroute.
