# Host baseline — users, patching, reboots

## Users

- A named unprivileged user with your SSH public key. Password auth off,
  root login off (`PermitRootLogin no`, `PasswordAuthentication no`).
- Sudo via group membership, not per-user sudoers edits.
- The ops-agent user comes later, in `server-health-report`. **Do not add any
  user to the `docker` group** — membership is equivalent to host root, since
  you can mount `/` into a container and write anywhere. It silently voids the
  read-only design.

## unattended-upgrades

Ships enabled on Ubuntu Server and runs daily. Two adjustments:

**Scope it to security origins only.** The default on some images pulls in more
than security updates, which means unreviewed feature changes arriving at 4am on
a production box.

```
// /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
```

**Dry-run before trusting it:**

```bash
sudo unattended-upgrade --dry-run --debug
```

## needrestart

On 22.04+, `needrestart` handles the gap between "patched library is on disk"
and "running processes still hold the old copy mapped in memory". Without it a
patched OpenSSL sits unused until something happens to restart the service —
which for a long-running container might be never.

```bash
sudo apt-get install -y needrestart
sudo needrestart -b     # batch mode: what still needs restarting
```

## Reboot-required alerting

Kernel and libc updates need a reboot. If auto-reboot is disabled — a reasonable
choice for a single production box with no redundancy — then **something must
tell you a reboot is pending**, or "no auto-reboot without monitoring" quietly
becomes "never reboot", and you accumulate unpatched kernels indefinitely.

The flag is a file:

```bash
test -f /var/run/reboot-required && echo "reboot needed"
cat /var/run/reboot-required.pkgs    # what asked for it
```

`server-health-report` reports this. Until that skill exists, a daily cron
posting to your alert channel is enough. The point is that the decision to
reboot stays with you while the *knowledge* that one is needed does not depend
on you remembering to check.

## The deliberate reboot

Before trusting an unattended 4am reboot, do one at a time you're watching:

```bash
sudo systemctl reboot
# then, from your machine
.claude/skills/vps-provision/scripts/verify.sh <target>
```

Then confirm every stateful unit is actually enabled:

```bash
systemctl list-unit-files --state=enabled | grep -E 'docker|tailscaled|cloudflared'
systemctl is-enabled docker tailscaled
```

A service that is *running* but was never `enable`d works perfectly until the
first reboot and then doesn't come back. That distinction is invisible in
`systemctl status`, which shows it happily active either way — and it is the
single most common reason a box that "rebooted fine in testing" comes up dead.

## Containers are not covered by any of this

`unattended-upgrades` patches the host. It does nothing for the base images your
containers run.

Handle those the other way round: **pin images by digest**, and make "a newer
base image digest is available" something `server-health-report` tells you about,
so updating is a decision you make with a rollback path rather than something
that happens to you.

Specifically, do **not** run Watchtower-style auto-pull on production. Silent
image replacement turns what should be a ten-second controlled restart into a
forty-minute outage at a time you didn't choose, with no obvious diff to point at.
