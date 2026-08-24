# Cloudflare Tunnel — the public plane

`cloudflared` opens an **outbound** connection to Cloudflare's edge and serves
traffic back down it. No inbound port is opened, TLS terminates at Cloudflare,
the origin IP is never associated with the domain, and volumetric attacks are
absorbed at the edge rather than by a single VPS.

## Locally-managed, not dashboard-managed

Cloudflare's 2026 default steers you toward **remotely-managed** tunnels: ingress
rules live in the dashboard, and the local `cloudflared` carries only a token.
It's genuinely convenient.

Use **locally-managed** anyway — `config.yml` in this repo. The reason is the same
one behind "reviewed artifacts to prod, no live editing": dashboard-managed
ingress is production routing configuration that lives outside the repository,
outside code review, and outside git history, changeable by anyone with dashboard
access and with no record of who changed what. That's the exact property this
architecture rejects everywhere else.

The token still authenticates the connector. Only the *routing* stays in the repo.

## Three things that each cost an hour

### The catch-all is not optional

```yaml
ingress:
  - hostname: api.example.com
    service: http://api:8000
  - service: http_status:404      # <- required, must be last
```

`cloudflared` evaluates ingress rules top to bottom and **requires** a
terminating rule with no hostname. Without it, an unmatched request fails in a
way that produces no useful error at either end.

### Service-name DNS needs a user-defined network

`service: http://api:8000` resolves `api` through Docker's embedded DNS, which
only works on a **user-defined** network. On the default bridge, name resolution
silently fails and you get connection errors that look like the app is down.

`cloudflared` and its target must share a network you declared in `compose.yml`.

### Pin the image, 2026.5.2 or newer

That release added startup connectivity pre-checks, which diagnose blocked egress
at boot instead of failing opaquely later. Given this architecture depends
entirely on outbound working, that diagnostic is worth having.

Pin by digest, consistent with the rest of the stack. `cloudflared:latest` on a
production box means an unreviewed binary change arrives whenever you happen to
restart.

## What goes through the tunnel, and what doesn't

**Through the tunnel, behind Cloudflare Access:** anything administrative that
genuinely needs browser access from anywhere.

**Through the tunnel, public:** the API. That's it.

**Never through the tunnel:** monitoring UIs, pgAdmin, dashboards, anything that
holds credentials or lets you change state. These bind to the Tailscale interface
and are reachable only from the tailnet.

The rule is worth stating plainly because the tunnel makes exposing something
*so* easy that it happens by accident: a bare tunnel hostname with no Access
policy is a public URL, indexed and scanned within days. If a hostname is going
through the tunnel and isn't the public API, it needs an Access policy before it
goes live, not after.

## Cloudflare Access

Access sits in front of a hostname and requires identity before any request
reaches your origin. For a solo operator, an email OTP policy scoped to your own
address takes about five minutes.

Service tokens exist for machine-to-machine calls (CI hitting a deploy hook, for
example) — those bypass the interactive login but still authenticate.

## The account is a single point of compromise

Tunnel, WAF, DNS, and the primary backup bucket all live in one Cloudflare
account. Compromise it and an attacker can reroute traffic, disable protections,
and reach the backups.

Two mitigations, and they cover different things:

- **Hardware-key 2FA on that account** — not TOTP. This is the highest-value
  fifteen minutes in the whole setup.
- **The Backblaze B2 second copy**, on a different vendor with a different
  account. Bucket locks defend against a compromised *server*; a second vendor
  defends against a compromised *account*. Neither substitutes for the other.

## Edge security worth turning on

Since nginx is dropped for launch, the edge is doing the work it would have done:

- **WAF rate limiting** per path — the API's rate limits live here now.
- **Request size caps** on upload endpoints.
- **Bot Fight Mode** or equivalent, if the API is browser-facing.

Configure these deliberately rather than assuming defaults cover it. If you later
reintroduce nginx for multi-service routing, these stay — defence in depth, not
either/or.
