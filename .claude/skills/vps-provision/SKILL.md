---
name: vps-provision
description: Harden a fresh Ubuntu VPS down to zero open inbound ports — unprivileged user, ufw, Docker FORWARD-chain rules, Tailscale as the admin plane, gated removal of public SSH, and a locally-managed Cloudflare Tunnel for public traffic. Use this whenever the user is provisioning, hardening, setting up, or locking down a server, VPS, droplet, or box, and whenever they mention Tailscale, cloudflared, ufw, closing ports, "no open ports", removing SSH from the internet, or bringing up a staging or production host. Also use it before the first deploy to any server this repo has not already provisioned, since deploy-api assumes these guarantees hold.
disable-model-invocation: true
---

# vps-provision

Bring a fresh Ubuntu LTS host to the state the rest of this repo assumes:
**ufw denies all inbound, nothing is published to the host, admin access is
Tailscale-only, and public traffic arrives through an outbound-only Cloudflare
Tunnel.**

Run it against **staging first, then production** — see [Why staging
first](#why-staging-first). It is mostly dormant after that.

## Stop and ask the user first

- Publishing any container port to the host. This is the moment ufw stops
  meaning what everyone assumes it means.
- Adding the ops-agent user to the `docker` group. Group `docker` is host root.
- Exposing a hostname through the tunnel with no Cloudflare Access policy.
- Skipping the two-session proof before removing public SSH.

## Before you touch anything

Confirm and write down the **out-of-band recovery path** — the provider's web
console, serial console, or rescue mode, and how to reach it. Provider-agnostic
means this differs per host, so it cannot be baked into a script, and it is the
only thing standing between a botched firewall rule and a rebuilt server. If you
cannot state how you would get back in, stop here.

Then fill in `infra/targets.env` (copy `infra/targets.env.example`). Every script
takes a named target, never a raw IP, so that irreversible actions can refuse to
run against prod without a human saying so.

## Sequence

Each phase ends in an assertion. Treat a command that exited 0 as *nothing*:
check the resulting state, because a rule that failed to apply and a rule that
applied to the wrong interface both exit 0.

### 1 · Base host

Unprivileged user with your SSH key, sudo, and hostname set. Then:

- `unattended-upgrades`, **scoped to security origins only** — `--dry-run`
  before rolling out, always.
- `needrestart`, which handles the case where a patched library is on disk but
  running processes still hold the old copy in memory.
- A **reboot-required alert**. If auto-reboot is off and nothing watches
  `/var/run/reboot-required`, "no auto-reboot without monitoring" quietly
  becomes "never reboot", which is the actual failure mode.

Details: `references/host-baseline.md`.

### 2 · Docker

Install Docker CE from Docker's own repository, not the distro package. Confirm
`docker compose version` works — the plugin, not the old `docker-compose` binary.

### 3 · Tailscale — the admin plane

Join the tailnet, disable key expiry for a server node (an expired key locks you
out of your own admin plane at 3am), and confirm `tailscale status` is healthy.

**Check the tailnet policy before tagging anything.** A new tailnet ships an
allow-all grant (`"src": ["*"], "dst": ["*"]`). Under it a `tag:ci` node — the
CI runner that deploys — can reach every machine you own, production included.
Change that grant's `src` to `["autogroup:member"]` (your own untagged devices
keep full access, nothing changes for them) and add narrow grants for the tags:

```jsonc
"tagOwners": { "tag:<server>": ["autogroup:admin"], "tag:ci": ["autogroup:admin"] },
"grants": [
  { "src": ["autogroup:member"], "dst": ["*"], "ip": ["*"] },
  { "src": ["tag:ci"], "dst": ["tag:<server>"], "ip": ["tcp:22"] }
]
```

First confirm no existing node is tagged
(`tailscale status --json | jq '.Peer[].Tags'`) — a tagged node is not a
`member` and would lose access under the narrowed grant.

### 4 · SSH cutover — the irreversible step

This is the highest-consequence step in the whole repo. Use the script; it
encodes the ordering and the assertions.

```bash
scp infra/scripts/ssh-cutover.sh <target>:/tmp/     # or push_script from common.sh
ssh <target> sudo /tmp/ssh-cutover.sh arm           # add the tailscale0 rule
# open a SECOND, independent ssh session over the tailnet now
ssh <target> sudo /tmp/ssh-cutover.sh check         # refuses unless it is safe
ssh <target> sudo /tmp/ssh-cutover.sh cutover       # deletes the public rules
```

The ordering matters more than any individual command:

1. Add the `tailscale0`-scoped rule for port 22.
2. Prove **two independent** tailnet sessions. Two, not one — if the first dies
   mid-cutover, the second is the repair path.
3. Identify the public rules **by number**.
4. Delete them **while both sessions stay open**.
5. Assert no unscoped SSH allow remains.

Step 5 is a **post-condition**. It cannot hold before step 4, because the public
rule is precisely what makes it false — a gate that checks it first can never
open, and the cutover never happens.

Two traps the script handles and hand-rolled versions usually don't:

- **`ufw allow OpenSSH`** renders as an application-profile name with no digits
  in it. Grepping for "22" sails straight past it and leaves the box open.
- **ufw renumbers** after every delete, so deleting low-to-high makes each
  subsequent number point at the wrong rule. The script deletes descending.

Do not close your proving sessions until a *fresh* tailnet connection succeeds.

Full walkthrough including recovery: `references/ssh-cutover.md`.

### 5 · Firewall

`ufw default deny incoming`, `default allow outgoing`, and the tailnet rule from
step 4. Then the Docker layer, which ufw does not cover:

```bash
ssh <target> sudo /tmp/docker-firewall.sh apply
ssh <target> sudo EGRESS_TEST=1 /tmp/docker-firewall.sh verify
```

ufw filters INPUT. Docker publishes ports through NAT and FORWARD, which never
touch INPUT — so a published port is reachable regardless of what `ufw status`
says. The stack publishes nothing, which makes this defence in depth, but the
guarantee should be mechanical rather than remembered.

**This is not a blanket DROP**, and the distinction matters enormously.
`DOCKER-USER` hangs off FORWARD, and container-*originated* traffic traverses
FORWARD too. A chain-wide drop kills cloudflared's connection to Cloudflare and
the backup uploader's reach to R2 — in an outbound-only architecture, that is
everything. The script releases `RELATED,ESTABLISHED` first, then drops new
inbound on the public interface, and asserts **both** properties: nothing new
gets in, *and* a container can still get out. The second assertion is the one
that catches the mistake.

Details: `references/firewall.md`.

### 6 · Cloudflare Tunnel

Use a **locally-managed** tunnel — `config.yml` in this repo, not the dashboard.
Remote-managed tunnels are the 2026 default, but they put production ingress
config outside the repo and outside review, which contradicts the "reviewed
artifacts to prod" decision this whole setup rests on.

Three things that cost an hour each if missed:

- The ingress list **needs a terminating `- service: http_status:404`**.
  Without it an unmatched request fails in a way that is genuinely miserable to
  debug.
- `cloudflared` and its target must share a **user-defined** network. Service-name
  DNS does not resolve on the default bridge.
- Pin the image, `2026.5.2` or newer — that version added startup connectivity
  pre-checks that diagnose blocked egress for you instead of failing opaquely.

Anything that is not the public API — dashboards, admin panels, pgAdmin,
monitoring UIs — goes behind Cloudflare Access or stays Tailscale-only. Never a
bare tunnel hostname.

Template: `infra/cloudflared/config.yml`. Details: `references/tunnel.md`.

### 7 · Prove it survives a reboot

Reboot deliberately, once, while you are watching — before trusting an
unattended 4am one.

```bash
ssh <target> sudo systemctl reboot
scripts/verify.sh <target>
```

Then check `systemctl is-enabled` on every stateful unit. A service that runs
but was never enabled comes back only until the first reboot.

## Provider notes: Hetzner Cloud

Hetzner lets you skip the cutover's risk entirely, and that is the better path
on a fresh box:

- Create a **Cloud Firewall with no inbound rules** and attach it *at server
  creation*. Nothing on the public IP is reachable from the first second.
- Put a **tagged, pre-approved, single-use Tailscale auth key** in cloud-init
  (`tailscale up --auth-key=… --advertise-tags=tag:<server>`), and the ufw rule
  `allow in on tailscale0 to any port 22`. Tagged nodes do not expire.
- There is then no public SSH to remove. Prove it from outside anyway:
  `nmap -Pn -p 22,80,443,5432 <public-ip>` — every port filtered.

The cloud-init user data is stored with the server, so the auth key must be
single-use and short-lived. Recovery is the console path in
`references/host-baseline.md`. The x86 CX line is the cheap one, but it is
not in every location — check before choosing the location.

## Running this with an agent

What a session driving this through Claude Code learned:

- **Run it outside auto mode.** Auto mode denies tailnet-policy edits, tag
  changes, OAuth-client and token creation and purchases outright, even after
  the human grants them in chat, and shows no approve prompt. In the default
  mode each one becomes a one-click approval.
- **Secrets never go through the agent.** For every token (R2, Tailscale OAuth,
  CI deploy key) the agent writes a small script that prompts with
  `read -rsp` and pipes the value straight to its destination
  (`rclone.conf` over SSH, `gh secret set` from stdin), then verifies it works.
  The human pastes; the agent never sees the value.
- **Purchases are the human's click** (the server, the R2 subscription). Have
  the form filled and the price stated, then hand over.
- **Read the target repo's own deploy docs first.** A project may already apply
  these skills (a `deploy/` directory, an `oppctl`); improvising a parallel
  setup and then discovering it costs more than looking.

## Verification

`scripts/verify.sh <staging|prod>` asserts the properties that define "done":

| | |
|---|---|
| External scan | Nothing answers on the public IP — 22, 80, 443, 5432 all closed |
| Admin plane | SSH over the tailnet works |
| Public plane | The tunnel hostname serves |
| Docker | Inbound dropped, **egress preserved** |
| Postgres | Not listening on any host interface |

If the external scan finds an open port, stop and fix it before deploying
anything. That single check is the whole point of the exercise.

## Why staging first

Step 4 is irreversible and can strand you. Rehearsing the full gate on a box
where lockout costs nothing converts the plan's largest risk into a dry run, and
the production pass then executes a sequence already proven end to end on
identical software.

It also answers the question a provisioning *skill* exists to answer: does this
work on a machine it was not written against? A runbook that has only ever run
on the box it was written for is not repeatable — it just hasn't been tested
yet. If staging does not come up clean from the skill alone, the skill isn't
done, and that is far better discovered on box two than on box one.

## Reference files

- `references/host-baseline.md` — users, unattended-upgrades, needrestart, reboot alerting
- `references/ssh-cutover.md` — the gate in full, including how to recover if it goes wrong
- `references/firewall.md` — ufw and DOCKER-USER, why they are separate problems
- `references/tunnel.md` — locally-managed cloudflared, Access policies, ingress rules
