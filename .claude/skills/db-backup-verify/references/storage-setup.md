# Storage setup — R2 primary, B2 secondary

## R2

### Create the token at the right tier

Dashboard → R2 → Manage API Tokens.

- Permission: **Object Read & Write**
- Scope: **the backup bucket only**
- Token type: **Account API token**, not User API token

Two of those three are the usual mistakes.

**Object, not Admin.** Only Object-tier tokens can be bucket-scoped, and — the
part that matters — an Admin token can edit bucket configuration, which means it
can remove the bucket lock and then delete every backup. The lock and the token
tier are two halves of one guarantee. `scripts/check-immutability.sh token`
probes this by attempting an Admin-only operation and requiring it to fail.

**Account, not User.** A User token inherits that person's permissions and goes
inactive if they're removed from the account. On a solo account that sounds
irrelevant right up until you reorganise something, and the failure mode is
silent: backups just stop.

### Location: give it a hint

With *Automatic* location, R2 places the bucket near whoever is clicking, or
somewhere else entirely. One session got **Asia Pacific** for a server in
Nuremberg. Choose **Provide a location hint → Western Europe (WEUR)**, or
whatever region is nearest the server. A hint keeps the default endpoint. A
*jurisdiction* (EU) changes the endpoint (below).

New accounts must add the R2 subscription first (free tier, card on file).
Until then every R2 URL redirects to the plans page.

### Getting the token onto the server

The token's secret is shown once. Never paste it into a chat or an agent. Use a
prompt that sends it straight to the host and proves it works:

```bash
read -rp "Access Key ID: " id; read -rsp "Secret: " secret; echo
printf '%s\n%s\n' "$id" "$secret" | ssh <target> '
  read -r id; read -r secret
  sudo sed -i -e "s|^access_key_id = .*|access_key_id = $id|" \
              -e "s|^secret_access_key = .*|secret_access_key = $secret|" <rclone.conf>
  docker run --rm -v <rclone.conf>:/config/rclone/rclone.conf:ro rclone/rclone lsd r2:<bucket>'
```

### The endpoint, and the EU trap

```
https://<ACCOUNT_ID>.r2.cloudflarestorage.com          # default
https://<ACCOUNT_ID>.eu.r2.cloudflarestorage.com       # EU jurisdiction buckets
```

Jurisdictional buckets are **only** reachable through their jurisdictional
endpoint. If you created an EU bucket — likely on a European host — the default
endpoint will not find it, and the error looks like bad credentials rather than
a wrong URL. This costs people an hour routinely.

### rclone

```ini
# ~/.config/rclone/rclone.conf
[r2]
type = s3
provider = Cloudflare
access_key_id = <token id>
secret_access_key = <token secret>
endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
```

`no_check_bucket = true` matters here: without it rclone tries to create the
bucket if it can't confirm it exists, which an Object-tier token cannot do —
producing a confusing failure on an otherwise correct setup.

### Bucket lock

```bash
npx wrangler r2 bucket lock add --help     # check current flags first
npx wrangler r2 bucket lock list <bucket>  # then assert the rule exists
```

Don't hardcode the flags. The syntax has moved between Wrangler versions, and
`check-immutability.sh lock` deliberately verifies via `list` rather than
trusting that `add` did what you meant. What matters is that a rule exists
covering the dump prefix — a rule scoped elsewhere protects nothing.

Two behaviours worth knowing before you need them:

- **Locks take precedence over lifecycle rules.** If a lifecycle rule would
  delete at 30 days but a lock requires 90, the object stays.
- **A bucket cannot be emptied while any lock rule is configured.** Teardown
  means removing rules first — a deliberate, human step, never something a
  cleanup script does quietly.

## B2

Different vendor, different account, different credentials. That separation is
the entire point: if it shares an account with R2 it defends against nothing
that bucket locks don't already cover.

```ini
[b2]
type = b2
account = <keyID>
key = <applicationKey>
hard_delete = false
```

Enable **Object Lock** on the bucket at creation — B2 cannot turn it on for an
existing bucket — with a 90-day compliance retention. Use an application key
scoped to that single bucket.

`hard_delete = false` keeps B2's own file-version history as one more layer
between a mistake and data loss.

## What each layer actually defends against

Worth being precise, because it's easy to buy one and assume you're covered:

| Threat | Defence |
|---|---|
| Server compromised, credentials stolen | Bucket lock — the token can't delete locked objects |
| Cloudflare account compromised | B2 copy on a second vendor |
| Object store reads your data | age encryption — both vendors hold ciphertext |
| Accidental `rclone delete` | Bucket lock plus B2 versioning |
| Backup job silently broken | `upload.sh check` freshness, checked against the remote |
| Backups unrestorable | The monthly drill |
| Escrowed key lost or corrupted | The monthly drill, again — it decrypts every time |

No single row covers another. The one most often skipped is the last two, which
is why the drill is non-negotiable rather than a nice-to-have.
