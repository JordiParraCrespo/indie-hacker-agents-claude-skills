# SSH cutover — removing public SSH without stranding yourself

Read this before running `scripts/ssh-cutover.sh` against a host you care about.

## What the gate is protecting against

Two distinct failure modes, and they pull in opposite directions:

1. **You delete the public rule and the tailnet path doesn't actually work.**
   The box is now unreachable except through the provider console.
2. **You think you've closed public SSH but you haven't.** The rule you deleted
   wasn't the one letting traffic in, and port 22 is still open to the internet
   while `ufw status` looks reassuring.

A gate that only defends against (1) tends to leave (2) wide open, and vice
versa. That's why the script both *proves the new path works* and *asserts the
old path is gone* — the two checks are independent and neither implies the other.

## The ordering, and why it is what it is

```
1. ufw allow in on tailscale0 to any port 22 proto tcp
2. open a second, independent tailnet session
3. identify the public rules by number
4. delete them, sessions still open
5. assert no unscoped SSH allow remains
```

**Step 5 is a post-condition, not a precondition.** This is the mistake worth
internalising: "assert no unscoped port-22 rule exists" *cannot* be true before
step 4, because the public rule is precisely what makes it false. Ordering the
assertion first produces a gate that can never open — the cutover silently never
happens, and you're left believing it did.

**Two sessions, not one.** If the single session you're relying on dies while
you're mid-delete — a flaky link, a laptop sleeping — you have nothing. The
second session costs one terminal and is the difference between "undo the rule"
and "find the provider console credentials".

**Sessions stay open across the deletion.** Deleting a firewall rule doesn't
terminate established connections, so the sessions you proved in step 2 survive
step 4 and remain your repair path. Close them only after a *fresh* tailnet
connection succeeds.

## Two traps that hand-rolled versions miss

### `ufw allow OpenSSH`

ufw ships application profiles. `ufw allow OpenSSH` produces a rule that renders
as:

```
[ 1] OpenSSH                    ALLOW IN    Anywhere
```

No digits. Any check that greps for `22` passes straight over it and reports the
box as closed while SSH is fully exposed. The script matches port 22, the
`OpenSSH` profile name, and a bare `ssh` token for this reason.

### ufw renumbers on every delete

Rule numbers are positional, not stable. Delete rule 2 and the old rule 3
becomes rule 2. Collecting `[2, 4, 5]` and deleting in that order deletes rule 2,
then whatever slid into position 4, then whatever slid into 5 — arbitrary rules,
silently. Always delete **descending**.

### Scoped to *an* interface isn't enough

`22/tcp on eth0 ALLOW IN` has an interface scope and is still fully public. The
check must be "scoped to the tailnet interface specifically", not "has an
interface".

## If it goes wrong

**You still have a session open.** Re-add the rule immediately — this is why the
sessions stay open:

```bash
sudo ufw allow in on tailscale0 to any port 22 proto tcp
sudo ufw status numbered
```

**You have no session.** Provider console (Hetzner Cloud Console, DigitalOcean
Recovery Console, or the equivalent) gives you a virtual serial terminal that
doesn't route through SSH or the firewall at all. From there:

```bash
sudo ufw allow 22/tcp        # temporarily reopen
sudo tailscale status        # diagnose why the tailnet path failed
```

Common causes, in rough order of frequency: the Tailscale node key expired (a
server node should have key expiry disabled), the tailnet ACL doesn't permit
your client to reach this node on 22, or `tailscaled` didn't come back after a
reboot because it was never `systemctl enable`d.

**Nothing works and you're rebuilding.** This is why staging goes first. If
you're reading this during a prod cutover and haven't done staging yet, stop and
do staging.

## Verifying from outside

The definitive check comes from off-box:

```bash
# should hang or refuse, never connect
timeout 5 bash -c 'exec 3<>/dev/tcp/<public-ip>/22' && echo STILL OPEN
```

`scripts/verify.sh <target>` does this along with the rest of the post-conditions.
An internal `ufw status` reading is evidence about configuration; a refused
connection from the internet is evidence about reality. Prefer the second.
