# Decision record

Supersedes handoff §2 where they conflict. Each entry is dated and carries its reasoning. Don't relitigate without adding a new dated entry.

---

## D1 · Backup topology — split containers

**Decided 2026-08-17.** Resolves [F1](01-review.md#f1--the-backup-job-contradicts-the-network-design-), the blocking conflict.

A dump sidecar sits on the `data` network (`internal: true`) and writes to a shared volume. A separate uploader holds the R2 credentials and internet access but has **no** database access.

**Why:** the alternative — one container on both networks — works, but that container can read every row *and* talk to the internet. That's the exact capability shape §7's read-only-agent reasoning exists to prevent; granting it to a backup job while denying it to the ops agent would be incoherent. Cost is one extra container and a volume.

---

## D2 · nginx — dropped for launch

**Decided 2026-08-17.** Resolves [F2](01-review.md#f2--nginx-the-cited-cve-is-real-but-it-is-the-wrong-one-to-stop-at-), [F3](01-review.md#f3--whether-nginx-stays-is-no-longer-a-neutral-open-question-).

`cloudflared` routes straight to the API. The nginx config stays in the repo, unwired, for the day a second service appears.

**Why:** for a single service, nginx duplicates work Cloudflare already does at the edge — rate limiting, request-size caps, buffering — while adding a network-facing C process with two critical RCE-class CVEs in one quarter, both in the rewrite module.

**On "just always run the latest nginx":** reasonable instinct, two problems.

1. **It wouldn't have helped.** CVE-2026-9256 was disclosed roughly nine days after CVE-2026-42945, in the same module. Running the version that fixed 42945 meant running "latest" and still being vulnerable. Always-latest shrinks the exposure window; it never closes it.
2. **It contradicts D-carried-over from handoff §6**, which mandates digest-pinned images and explicitly rejects Watchtower-style auto-pull. Always-latest *is* auto-pull. Manual bumps instead means being as current as the last manual bump — weeks, for a solo dev.

**Reversal condition:** a second service within ~2 months. Keeping nginx now is cheaper than re-plumbing later. At that point the version floor must cover **both** CVEs and the config gets a lint for 9256's trigger — overlapping PCRE captures with a multi-capture replacement in redirect/args context.

**Side effect:** the `edge` and `app` networks collapse into one. Two networks, not three.

---

## D3 · API stack — agnostic, via a declared contract

**Decided 2026-08-17.** Supersedes handoff §9's open question.

`deploy-api` is written stack-agnostic. The project declares what the skill needs in a small manifest; the skill reads it rather than inferring it.

**Contract the app must satisfy:**

| | |
|---|---|
| Health endpoint | Path + expected status. Must not depend on the DB being writable. |
| Migration command | Apply, and the down path (or an explicit statement that it's irreversible, and why) |
| Listen port | Container-internal only — nothing publishes to the host |
| Build | Path to Dockerfile, digest-pinned base |
| Readiness | How to tell "started" from "serving" |

**Why:** this is a skills repo. A `deploy-api` hardcoded to one framework is a Dockerfile with extra steps. Making the contract explicit is what makes it reusable — and it forces the migration rollback plan to be declared rather than assumed, which handoff §8 correctly identifies as the thing an agent cannot infer.

**Consequence:** Phase 3 is no longer blocked on choosing a stack. Ships with two or three worked reference implementations to prove the contract holds.

---

## D4 · Staging — yes, on a separate server

**Decided 2026-08-17.** Changes handoff §9's assumed "no".

A second, smaller VPS. Not a second compose project on the prod box.

**Why separate:** same-box staging shares the blast radius. A runaway migration, a memory-exhausting query, or a bad image takes production with it — which defeats the purpose of having a rehearsal environment at all.

**The stronger reason:** the second server is the acceptance test for `vps-provision`. A provisioning skill that has only ever run once, on the box it was written against, is a runbook — not a repeatable process. Standing up staging from scratch is what proves the skill works, and it's the only honest way to find out before it matters.

**Consequences, and they're good ones:**

- **Phase 1 runs staging first.** [F7](01-review.md#f7--the-ssh-deletion-step-needs-a-hard-gate-not-a-sentence-) — deleting public SSH — is the highest-consequence step in the whole plan. Rehearsing it on a box where lockout costs nothing, before touching the box that matters, removes most of that risk. This is a material improvement to the plan and came out of the staging decision.
- Phase 3 gains environment promotion: staging deploy → verify → prod deploy. Same artifact, different target.
- A future remediation agent has somewhere legitimate to run (handoff §7 already requires staging-only for that).
- Cost: one small instance, and Phase 1 runs twice — which was the point.

---

## D5 · Domain and Cloudflare zone

**Open.** Blocks the tunnel step in Phase 1. Needed: the domain, and confirmation the zone is on the Cloudflare account that will hold the tunnel.

---

## D6 · Drill-failure alert channel

**Proposed: ntfy.** No SMTP to configure, push straight to phone, ~10 minutes of setup. Awaiting confirmation.

This is the one alert that pages (handoff §5). Everything else is a report.

---

## Carried over from the handoff, unchanged

Ubuntu LTS + Docker + ufw, host as a variable · Cloudflare Tunnel for public ingress · Tailscale for admin, public SSH deleted · Cloudflare Access on anything that isn't the public API · R2 primary with 30-day bucket lock, B2 secondary with 90-day Object Lock · three Postgres roles · ops agent read-only, forever · reviewed artifacts to prod, no live agent editing.
