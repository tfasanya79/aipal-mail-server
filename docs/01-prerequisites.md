# Prerequisites

Everything below was **verified against the live server on 2026-10-25**, not copied
from a tutorial. Re-run `sudo ./scripts/00-preflight.sh` any time to re-check.

## The actual server

| Property | Value |
| --- | --- |
| Provider / plan | Hostinger **KVM 8** |
| Location | France – Paris |
| OS | Ubuntu **24.04.4 LTS** (KVM, kernel 6.8) |
| CPU / RAM / Disk | 8 vCPU / **32 GiB** / 400 GiB NVMe (≈332 GiB free) |
| Public IPv4 | `187.55.230.139` |
| Hostname (current) | `srv1848374.hstgr.cloud` → changed to `mail.aipalassist.com` |
| Docker | 29.6.2, Compose v5.3.1 |
| Swap | **0 B** → bootstrap adds a 2 GiB swapfile |

## Port 25: the answer for this host

> **Port 25 outbound is OPEN on Hostinger VPS.**

This is the single most important fact and it is *good news* — it means no paid
SMTP relay is required. Verified empirically from the box:

```
TCP 25 -> gmail-smtp-in.l.google.com : OPEN
TCP 25 -> aspmx.l.google.com         : OPEN
TCP 587 -> smtp.gmail.com            : OPEN
```

Hostinger's documented policy is that port 25 is open but **outbound mail is
rate-limited to roughly 5 messages/minute per server**. That is ample for
business mailboxes (`info@`, `steve@`, …); it is *not* suitable for bulk
sending, and it is deliberately incompatible with mailing-list blasts.

If you ever outgrow it, the fix is a relayed smart host (SMTP2GO free tier,
Amazon SES, Mailgun) — Mailcow supports this natively via a relayhost. **You do
not need this to start.**

## Two things on this host that a generic tutorial would get wrong

### 1. Ports 80/443 are already taken by Caddy

An existing **Caddy 2.6.2** instance owns `0.0.0.0:80` and `0.0.0.0:443` and
serves other live services (`aipal-v2`, `timfas.com`, portfolio, gambler,
TenancyDesk, goatcounter…). It must keep working.

Therefore Mailcow **cannot** bind 80/443. It is installed loopback-only:

```conf
HTTP_BIND=127.0.0.1
HTTP_PORT=8080
HTTPS_BIND=127.0.0.1
HTTPS_PORT=8443
```

and Caddy proxies `mail.aipalassist.com` → `127.0.0.1:8080` while holding the TLS
certificate. This is the officially documented Mailcow-behind-Caddy setup.

### 2. UFW is active — do not blindly "disable it"

```
Status: active
Default: deny (incoming), allow (outgoing), deny (routed)
Allowed: 80/tcp, 443/tcp, 22/tcp
```

Mailcow's docs tell you to disable UFW. **On this box that would be reckless** —
UFW is what keeps SSH and the other sites' surface sane. Instead:

- keep UFW enabled,
- add `allow` rules for the mail ports (25/465/587/143/993/110/995/4190),
- accept that Docker publishes container ports through its own iptables chains
  (which is why the mail ports become reachable — those ports are *supposed* to
  be public).

Never run `ufw --force reset` or `ufw disable` on this host.

## RAM: a footnote to Copilot's answer

Copilot said "2 GB RAM minimum". That is **wrong** — Mailcow's own documentation
states **6 GiB + 1 GiB swap minimum**, 8 GiB recommended for 5–10 users. With
32 GiB this host is comfortably over-spec, so we keep ClamAV and full-text search
enabled (`SKIP_CLAMD=n`, `SKIP_FTS=n`).

## Domain state (GoDaddy DNS)

Nameservers: `ns49.domaincontrol.com`, `ns50.domaincontrol.com`.

Current, verified records relevant to mail — note the pre-existing DMARC:

| Record | Current value |
| --- | --- |
| `aipalassist.com` A | `216.198.79.1` (GoDaddy website builder — **leave alone**) |
| `mail.aipalassist.com` A | *none* — you will create it |
| `aipalassist.com` MX | *none* — you will create it |
| `aipalassist.com` TXT (SPF) | *none* — you will create it |
| `_dmarc.aipalassist.com` TXT | `v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;` |

That DMARC record is **GoDaddy's default**, not something you configured. It
already says `p=quarantine` while the domain has no SPF and no DKIM — so any mail
you send right now is unprotected. You will **edit** it, not add a second one.

## Reverse DNS

| | |
| --- | --- |
| Current PTR | `139.230.55.187.in-addr.arpa` → `srv1848374.hstgr.cloud` |
| Required PTR | `187.55.230.139` → `mail.aipalassist.com` |

Set in **hPanel** (VPS → server → Network → IPv4 → Reverse DNS). Not a GoDaddy
record. It is a strong deliverability signal; most receiving servers tolerate a
mismatch but Gmail/Outlook score you on it.

## IP reputation

Checked against the major blocklists from the box's own resolver:

```
clean  zen.spamhaus.org        clean  bl.spamcop.net
clean  b.barracudacentral.org  clean  dnsbl.sorbs.net
clean  cbl.abuseat.org         clean  all.s5h.net
```

A clean, dedicated datacenter IP is a decent starting point — far better than
what shared-range providers usually give you.

## What you need before starting

- [ ] Root (or passwordless sudo) on the VPS — *confirmed available*
- [ ] GoDaddy login for `aipalassist.com`
- [ ] Hostinger hPanel access (for PTR)
- [ ] ~30–45 minutes
- [ ] Zero recurring cost: Mailcow (AGPL), Caddy (already running, self-signed
      via Let's Encrypt), GoDaddy DNS, all free

## Time / risk estimate

| Phase | Time | Reversible? |
| --- | --- | --- |
| Bootstrap (swap, hostname, firewall) | 3 min | Yes |
| Mailcow pull + start | 10–15 min | Yes (`docker compose down`) |
| Caddy block + cert issuance | 3 min | Yes (auto-rollback on invalid config) |
| DNS records + propagation | 5 min + TTL | Yes |
| PTR change | 2 min + propagation | Yes |
| Verify + test mail | 10 min | — |

**Receiving** mail is low-risk. **Sending** mail into Gmail/Outlook inboxes is the
hard part — see [operations](04-operations.md#deliverability-warm-up).
