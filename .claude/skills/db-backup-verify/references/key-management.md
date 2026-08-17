# The encryption key

Backups are encrypted with [age](https://github.com/FiloSottile/age): one public
key encrypts, one private key decrypts. The public key goes on the server; the
private key never does.

## Generate

Do this on your own machine, never on the server.

```bash
age-keygen -o backup-key.txt
# Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

The file contains both halves. The `age1...` line is the public key — that is
what goes into `AGE_RECIPIENT` in the dump sidecar's environment, and it is not
sensitive.

## Escrow — the part that actually matters

**An unescrowed key turns every backup into ciphertext nobody can open.** This
is a real way to lose all your data while every backup job reports success and
every object sits safely under a 30-day lock.

Store the private key in at least two places that fail independently:

1. Your password manager, as a secure note.
2. Something offline that survives losing your laptop and your password manager
   at once — printed and filed, or on an encrypted USB stick in a different
   building.

The second copy sounds excessive until you consider that the scenarios where you
need backups — fire, theft, ransomware — are exactly the scenarios that take out
a single copy of the key.

### Where it must never be

- The app server. It has no reason to decrypt anything; only the drill does.
- The repository, encrypted or otherwise.
- Any environment variable in `compose.yml`.
- The backup buckets. A key stored beside the ciphertext protects nothing.

## Use

The drill takes the private key at run time and never persists it:

```bash
AGE_IDENTITY=/path/to/backup-key.txt scripts/restore-drill.sh run
```

If the drill runs on a schedule, the key needs to reach that host somehow. Order
of preference:

1. A dedicated admin machine on the tailnet that already holds it.
2. A secrets manager the scheduled job authenticates to at run time.
3. Manual monthly runs. Perfectly respectable for a solo operator, and it
   guarantees a human sees the result.

What to avoid is copying the key onto the production host to make scheduling
easier — that hands the decryption key to the machine most likely to be
compromised, and quietly undoes the reason for encrypting.

## The drill tests the key, not just the backups

This is worth stating explicitly because it's easy to miss: every drill run
decrypts a real dump with the escrowed key. So a passing drill proves three
things at once — the backup exists, it restores, **and the key still opens it**.

Nothing else in the pipeline would notice a corrupted, truncated, or
accidentally-rotated key. The dump job would keep encrypting happily to a public
key whose private half no longer works, and you'd find out during an incident.

## Rotation

Rotating the key does **not** re-encrypt existing backups — old dumps still need
the old key. So rotation means keeping both:

1. Generate a new keypair.
2. Update `AGE_RECIPIENT` on the dump sidecar; new dumps use the new key.
3. **Keep the old private key escrowed** for as long as any backup encrypted
   with it is still within retention — at least 90 days for the B2 copies.
4. Run the drill against a pre-rotation dump *and* a post-rotation one, so both
   paths are proven before you rely on either.

Label the escrowed copies with their date range. "Which key opens the dump from
March" is a question you do not want to answer under pressure.

## Encrypting to more than one key

`age` accepts multiple recipients, and a second recipient is a reasonable hedge
against losing the primary key:

```bash
age -r "$PRIMARY" -r "$SECONDARY" -o out.age in.pgc
```

Worth it if a second person should be able to restore — a co-founder, or a
break-glass key held somewhere separate. It's a genuine tradeoff rather than a
free win: each additional recipient is another key that can decrypt every
backup, so add one for a reason, not by default.
