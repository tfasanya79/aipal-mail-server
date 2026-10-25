# DNS (GoDaddy) and reverse DNS

Do this **before** installing, because Caddy can only obtain a certificate once
`mail.aipalassist.com` resolves to the server.

Generate the exact values — including the DKIM key — with:

```bash
sudo ./scripts/05-dns-records.sh
```

That command must be re-run **after** you add the domain in the Mailcow UI,
because DKIM keys are generated per-domain by Mailcow.

## Records to create in GoDaddy

GoDaddy DNS → `aipalassist.com` → **DNS / Manage DNS** → *Add New Record*.

| # | Type | Name (Host) | Value | TTL | Priority |
| --- | --- | --- | --- | --- | --- |
| 1 | `A` | `mail` | `187.55.230.139` | 1 hour | — |
| 2 | `MX` | `@` | `mail.aipalassist.com` | 1 hour | `10` |
| 3 | `TXT` | `@` | `v=spf1 mx ~all` | 1 hour | — |
| 4 | `TXT` | `dkim._domainkey` | *(from script — long `v=DKIM1; k=rsa; p=…`)* | 1 hour | — |
| 5 | `TXT` | `_dmarc` | `v=DMARC1; p=none; rua=mailto:dmarc@aipalassist.com; adkim=r; aspf=r; pct=100` | 1 hour | — |
| 6 | `A` | `autodiscover` | `187.55.230.139` | 1 hour | — |
| 7 | `A` | `autoconfig` | `187.55.230.139` | 1 hour | — |

Records 6–7 are optional but make Outlook/Thunderbird auto-configure themselves
instead of asking the user for server names.

### Do not touch

- The apex `A` record (`@` → `216.198.79.1`) — that is the GoDaddy website
  builder and has nothing to do with mail.
- `www` — likewise unrelated.
- Do **not** add a second `MX`. Exactly one is correct here.

## The DMARC record already exists

GoDaddy pre-created:

```
_dmarc.aipalassist.com  TXT  "v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;"
```

**Edit that existing record** rather than creating another (two DMARC records =
invalid). Replace it with the staged policy in row 5.

Why `p=none` first: with no SPF/DKIM the domain currently fails DMARC. Starting
at `p=none` lets you read aggregate reports without risking silent mail loss.
After 1–2 weeks of clean reports:

```
v=DMARC1; p=quarantine; rua=mailto:dmarc@aipalassist.com; adkim=r; aspf=r; pct=100
```

then eventually `p=reject`. Set `DMARC_POLICY=quarantine` in `.env` and re-run
the script when you tighten it.

> The `rua` mailbox must exist. Create `dmarc@aipalassist.com` as a real mailbox
> or an alias, otherwise reports are lost.

## SPF rules of thumb

- Exactly **one** `v=spf1` record per domain. Adding a second breaks both.
- `mx` means "the hosts in my MX records may send" — that's your Mailcow box.
- `~all` = soft fail while you ramp up. Move to `-all` (hard fail) once DKIM and
  DMARC are confirmed passing.

## Reverse DNS (PTR) — set at Hostinger, NOT GoDaddy

PTR belongs to the IP address, so the domain registrar can't set it.

**Hostinger does not reliably expose PTR in hPanel's VPS settings** (their VPS
"Main settings" page has root password, firewall and hostname reset — no reverse
DNS field). Changing the VPS hostname does **not** update the PTR automatically.

In order of preference:

### 1. hPanel → VPS → Settings → IP address
Some plans surface a "Reverse DNS" / "PTR" field on that page. Check it first.

### 2. Hostinger API (works regardless of the UI)

Create a token at **hPanel → API**, then:

```bash
# 1. find your VM id and the IP address id
curl -s -H "Authorization: Bearer $HOSTINGER_TOKEN" \
  https://developers.hostinger.com/api/vps/v1/virtual-machines | jq '.data[] | {id, hostname}'

# 2. set the PTR
curl -s -X POST \
  -H "Authorization: Bearer $HOSTINGER_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"domain":"mail.aipalassist.com"}' \
  "https://developers.hostinger.com/api/vps/v1/virtual-machines/${VM_ID}/ptr/${IP_ID}"
```

The response is an action object (`state: success`), not the record itself.
There is also a CLI: `hostinger vps ptr create <vm-id> <ip-id> --domain mail.aipalassist.com`.

### 3. Support ticket

"Please set the PTR/rDNS for `187.55.230.139` to `mail.aipalassist.com`." Routine
request, usually handled quickly.

### Verify

```bash
dig +short -x 187.55.230.139
# must print: mail.aipalassist.com.
```

If hPanel has no PTR field for your plan, open a Hostinger ticket and ask them to
set the PTR for `187.55.230.139` to `mail.aipalassist.com`. It is a routine
request.

Forward and reverse **must match**:

```
A    mail.aipalassist.com -> 187.55.230.139
PTR  187.55.230.139       -> mail.aipalassist.com
```

## Propagation checks

```bash
dig +short A    mail.aipalassist.com  @1.1.1.1
dig +short MX   aipalassist.com       @1.1.1.1
dig +short TXT  aipalassist.com       @1.1.1.1
dig +short TXT  dkim._domainkey.aipalassist.com @1.1.1.1
dig +short TXT  _dmarc.aipalassist.com @1.1.1.1
dig +short -x   187.55.230.139        @1.1.1.1
```

GoDaddy's minimum TTL is 1 hour. Mailcow's own DNS sanity guide is worth a read:
<https://docs.mailcow.email/getstarted/prerequisite-dns/>

When all six commands return what you expect, run `./scripts/07-verify.sh`.
