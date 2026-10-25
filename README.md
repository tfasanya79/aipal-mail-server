# AiPal Mail Server

Self-hosted email for **`aipalassist.com`** on a Hostinger KVM 8 VPS —
built to be **$0/month**, **non-destructive to the sites already on that box**,
and reproducible from this repo.

> This repo exists because the original advice (a generic ChatGPT/Copilot answer)
> was about 85% right and dangerously wrong on the three points that actually
> decide whether it works on *this* server. Those corrections are the point.

---

## TL;DR

```bash
git clone https://github.com/tfasanya79/aipal-mail-server.git
cd aipal-mail-server
cp .env.example .env            # edit if your IP/domain differ

sudo ./scripts/00-preflight.sh     # read-only report — start here
sudo ./scripts/01-bootstrap-host.sh
# → create the A record for mail.aipalassist.com in GoDaddy, wait for it
sudo ./scripts/02-install-mailcow.sh
sudo ./scripts/03-caddy-setup.sh
sudo ./scripts/04-deploy-certs.sh
# → add domain + mailboxes in https://mail.aipalassist.com (admin/moohoo)
sudo ./scripts/05-dns-records.sh    # enter MX/SPF/DKIM/DMARC in GoDaddy
# → set PTR in Hostinger hPanel
./scripts/07-verify.sh
```

Full walkthrough: **[docs/03-install.md](docs/03-install.md)**.

---

## Architecture

The decisive constraint: **Caddy 2.6.2 already owns `0.0.0.0:80` and `:443`** on
this host, serving `aipal-v2` and several other live sites. Mailcow therefore
cannot have them. It binds loopback and Caddy fronts it.

```
                            Internet
                                │
        ┌───────────────────────┼────────────────────────┐
        │                       │                        │
   TCP 25/465/587          TCP 993/143              TCP 443/80
   (mail transfer)         (IMAP clients)           (web UI)
        │                       │                        │
        │                       │                        ▼
        │                       │              ┌─────────────────────┐
        │                       │              │  Caddy 2.6.2        │
        │                       │              │  :80 :443           │
        │                       │              │  TLS + ACME         │
        │                       │              └──────────┬──────────┘
        │                       │                         │ reverse_proxy (TLS)
        │                       │                         │ mail.aipalassist.com
        ▼                       ▼                         ▼ 127.0.0.1:8443
  ┌──────────────────────────────────────────────────────────────────┐
  │  Mailcow: dockerized                                             │
  │  postfix · dovecot · rspamd · clamav · SOGo · roundcube · mysql  │
  │  nginx bound to 127.0.0.1:8080 / :8443                           │
  └──────────────────────────────────────────────────────────────────┘
        ▲ cert.pem / key.pem
        │
  scripts/04-deploy-certs.sh  (hourly cron: copies Caddy's cert in)
```

Key design decisions:

- **Caddy terminates TLS**; Mailcow's own ACME is disabled
  (`SKIP_LETS_ENCRYPT=y`) because two ACME clients fighting over port 80 fails.
  The hourly cron shares Caddy's certificate with Postfix/Dovecot so **993/465/587
  present the same valid cert** as the web UI.
- **Ports 80/443 are never touched** — Mailcow uses `8080`/`8443` on loopback.
  Caddy proxies to **`https://127.0.0.1:8443`**, not the plain-HTTP port: Mailcow's
  nginx answers any request on `HTTP_PORT` with an unconditional `301` to HTTPS,
  so an HTTP upstream would redirect-loop forever.
- **UFW stays enabled.** Mailcow's docs say to disable it; on a shared multi-app
  host that's reckless. We add allow rules instead.
- **No outbound relay.** Port 25 egress works (verified), so nothing costs money.

---

## What the generic answer got wrong

| Claim in the original answer | Reality on this host | Impact |
| --- | --- | --- |
| "2 GB RAM minimum" | Mailcow requires **6 GiB + 1 GiB swap** ([docs](https://docs.mailcow.email/getstarted/prerequisite-system/)). Host has 32 GiB, so fine — but the number was wrong. | Low here, fatal on a small VPS |
| "Open the VPS firewall with `ufw allow 25 …` then `ufw enable`" | UFW was **already active** and protects SSH + the other sites. Mailcow's docs actively warn against UFW with Docker. Enable-then-allow is wrong order and risks existing services. | **High** |
| "Port 25 might be blocked — ask Hostinger to unblock it or use a relay" | **Port 25 is open.** Verified by TCP connection to Gmail's MX from the box. Hostinger rate-limits to ~5 msg/min but does not block. | **High — relaying is unnecessary** |
| "Set MX, SPF, DKIM, DMARC" (implied clean slate) | A **GoDaddy default DMARC record already exists** (`p=quarantine`, `rua` → `onsecureserver.net`). Adding a second one is invalid; it must be *edited*. | Medium |
| "Use `mail.aipalassist.com` as mailcow hostname" | Correct — but installing Mailcow normally binds :80/:443 and would **collide with Caddy**. The documented reverse-proxy path is required. | **High** |
| Generic: "point PTR at your mail host" | Correct and important; current PTR is `srv1848374.hstgr.cloud`. Set in **hPanel**, not GoDaddy. | Medium |

Also silently missing from the original: swap was 0 B, and the system hostname
was `srv1848374.hstgr.cloud`.

---

## Verified environment

Everything in [docs/01-prerequisites.md](docs/01-prerequisites.md) was checked
against the live server, not assumed:

| | |
| --- | --- |
| Host | Hostinger KVM 8, Ubuntu 24.04.4 LTS, Paris |
| Resources | 8 vCPU / 32 GiB RAM / ~332 GiB free |
| IPv4 | `187.55.230.139` |
| Port 25 egress | **open** (Gmail MX reachable) |
| Mail ports 25/465/587/143/993/110/995/4190 | all free |
| Ports 80/443 | owned by Caddy 2.6.2 → proxied |
| UFW | active (22/80/443) → extended, never disabled |
| Swap | 0 B → 2 GiB added |
| PTR | `srv1848374.hstgr.cloud` → change to `mail.aipalassist.com` |
| Blocklists | clean on Spamhaus/SpamCop/Barracuda/SORBS/CBL |
| DNS | GoDaddy (`ns49/ns50.domaincontrol.com`); no MX/SPF/DKIM; default DMARC present |

---

## Repository layout

```
.
├── README.md
├── .env.example              # copy → .env (gitignored)
├── Makefile                  # make preflight / install / verify / ...
├── config/
│   ├── Caddyfile.mailcow.snippet
│   └── mailcow.conf.overrides
├── scripts/
│   ├── lib/common.sh         # shared helpers, set_conf, probes
│   ├── 00-preflight.sh       # read-only readiness report
│   ├── 01-bootstrap-host.sh  # packages, hostname, swap, firewall
│   ├── 02-install-mailcow.sh # clone + configure + start (loopback only)
│   ├── 03-caddy-setup.sh     # proxy via Caddy, validate, auto-rollback
│   ├── 04-deploy-certs.sh    # share Caddy cert w/ mail services + cron
│   ├── 05-dns-records.sh     # print GoDaddy records incl. DKIM
│   ├── 06-create-mailbox.sh  # create mailbox via API
│   └── 07-verify.sh          # end-to-end verification
└── docs/
    ├── 01-prerequisites.md   # verified facts, gotchas
    ├── 02-dns-godaddy.md     # records, DMARC edit, PTR
    ├── 03-install.md         # ordered walkthrough
    ├── 04-operations.md      # backups, updates, warm-up, monitoring
    └── 05-troubleshooting.md # symptom → cause
```

All scripts are `bash`, idempotent, and `set -euo pipefail`. `03-caddy-setup.sh`
**validates Caddy and rolls back** rather than risking the other sites.

---

## How successful is this, realistically?

Honest split, because "will it work" has two different answers:

| Goal | Confidence | Why |
| --- | --- | --- |
| Server up, receiving mail reliably | **~90%** | Port 25 inbound fine, Mailcow is mature, DNS is straightforward |
| Sending mail that reaches Gmail/Outlook **inboxes** | **~70% initially**, ~90% after warm-up | Clean IP + PTR + SPF/DKIM/DMARC is solid, but a new domain has no sending history |

The technical setup is the easy 90%. The remaining risk is **reputation**, not
configuration — which is why [deliverability warm-up](docs/04-operations.md#deliverability-warm-up)
is a documented step and not an afterthought.

Two ongoing obligations make or break it long-term:

1. **Backups off-host.** This VPS also runs production apps, and Hostinger's
   abuse team has a documented history of suspending accounts without warning.
2. **Monthly `update.sh`.** An unpatched internet-facing mail server is a
   liability, not an asset.

---

## Cost

| Item | Cost |
| --- | --- |
| Mailcow (AGPL-3.0) | $0 |
| TLS (Let's Encrypt via Caddy) | $0 |
| GoDaddy DNS | $0 |
| Outbound relay | not needed |
| **Incremental monthly** | **$0** |

## Requirements

- Root/sudo on the target host
- Root shell is assumed; scripts re-exec nothing and check `EUID`
- GoDaddy access to the domain, Hostinger hPanel for PTR
- Docker ≥ 24 (29.6.2 present)

## Security

- Never commit `.env` (gitignored) — it holds the mailcow API key.
- Change `admin / moohoo` before exposing anything, and enable 2FA.
- Prefer 993/465/587; keep 143/110 closed.
- Backup artifacts (`*.pem`, `*.key`) are gitignored.

## License

[MIT](LICENSE) for the tooling in this repo. Mailcow itself is AGPL-3.0 and is
cloned at install time, not vendored here.

## References

- Mailcow system prerequisites — <https://docs.mailcow.email/getstarted/prerequisite-system/>
- Mailcow behind Caddy — <https://docs.mailcow.email/post_installation/reverse-proxy/r_p-caddy2/>
- Mailcow reverse-proxy overview — <https://docs.mailcow.email/post_installation/reverse-proxy/r_p/>
- Hostinger VPS port 25 policy — <https://www.hostinger.com/support/7854530-is-smtp-port-25-blocked-on-hostinger-vps/>
