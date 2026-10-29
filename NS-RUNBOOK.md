# NS run-book

The commands to run on the server when it is back. Everything here is checked and
reversible; nothing deletes data. Run them in order, from the repository clone on the
server, inside `deploy/self-hosting` (the folder with `docker-compose.yml` and `.env`).

## 0. Get the NS branch onto the server (once)

```bash
cd ~/fluxer                     # your clone of github.com/uppablo444/fluxer (adjust the path)
git status                      # must show no changes you care about; commit or stash them first
git fetch origin
git checkout ns/main
cd deploy/self-hosting
```

## 1. Health and safety report (read-only)

```bash
bash ns/ns-check.sh
```

Shows the running versions, which secrets are missing or still placeholders (never their
values), security settings, memory and recent errors. The output is safe to share.

## 2. Backup, with a restore drill

```bash
bash ns/ns-backup.sh                                   # asks before the short downtime
bash ns/ns-backup.sh --offsite you@other-machine:/backups/ns   # also copies it off this machine
```

- Dumps the database while NS keeps running, checks the dump, then stops NS for a few
  minutes to copy the uploads consistently, and starts it again (also on failure).
- Restores the dump into a throwaway, network-less Postgres and compares row counts.
  It only says `Restore drill PASSED` when that worked.
- Writes `backups/ns-backup-<time>/` with `fluxer.dump`, `seaweedfs-data.tgz`,
  `env.backup` (all secrets: keep it private), checksums and `RESTORE-DRILL-PASSED`.
- `--db-only` skips the uploads copy and therefore the downtime.

A backup that stays on the same laptop does not survive that laptop. Use `--offsite`, or
copy the folder elsewhere.

**Restoring** (only if something went wrong). This REPLACES the current database and
uploads with the backup, so take a fresh backup of the current state first if you might
want it back. These are the official steps from `fluxer_docs/.../operator/upgrading.mdx`:

```bash
docker compose stop
docker compose up -d --wait postgres
docker compose exec -T postgres sh -c 'pg_restore -U $POSTGRES_USER -d $POSTGRES_DB --clean --if-exists' \
  < backups/ns-backup-<time>/fluxer.dump
docker compose stop
docker run --rm -v fluxer_seaweedfs-data:/data -v "$PWD/backups/ns-backup-<time>:/backup:ro" alpine:3.22 \
  sh -c 'find /data -mindepth 1 -delete && tar xzf /backup/seaweedfs-data.tgz -C /data'
docker compose up -d
```

`fluxer_` is the Compose project name that `ns-check.sh` prints. Success: an existing
attachment opens again.

## 3. Deploy the NS client

```bash
bash ns/ns-deploy.sh --dry-run      # optional: prepare and show, change nothing
bash ns/ns-deploy.sh                # build (20-60 min the first time) and switch
```

What it does:

1. Reads the source revision of the **running** api image (label
   `org.opencontainers.image.revision`, or the release tag of its build version). It never
   guesses: if it cannot tell, it stops. If you built the server yourself, pass
   `--revision <full commit id>`.
2. Creates a separate git worktree at exactly that revision (your files are not touched)
   and applies the NS customizations with `ns/ns-apply.sh`. Every edit must match exactly,
   or it stops and names it.
3. Builds `ns/app-proxy:<revision>-ns.<tree>` with the same settings as the official
   self-hosted image.
4. Writes `docker-compose.ns.yml` (with a record of what was pinned), adds it to
   `COMPOSE_FILE` in `.env` (a dated copy of `.env` is saved first; only that line changes),
   switches **only** `app-proxy`, and waits for it to be healthy.
5. If it is not healthy, it puts back the previous client automatically.

Go back to the stock client at any time:

```bash
bash ns/ns-deploy.sh --rollback
```

## 4. Smoke test (in the browser)

With two accounts: register and log in, send / edit / delete a message, react, upload an
image, open a DM, join voice (camera if you have one), reload the page. Then:

```bash
bash ns/ns-check.sh      # the error counts at the end should not have jumped
```

## Changing the NS name or colour

Edit the settings at the top of `deploy/self-hosting/ns/ns-apply.sh`, commit, push, then run
`bash ns/ns-deploy.sh` on the server again.

## What is in the NS branch

| Change | Where |
| --- | --- |
| Name NS, blurple `#5865F2`, install name, description | `ns/ns-apply.sh` (applied at build time) |
| Desktop title bar draws "NS", not the Fluxer wordmark | `FluxerWordmark.tsx` + test |
| Dead "Toggle the soundboard" keybind removed (frees Ctrl/Cmd+Shift+B) | `InputKeybind.ts`, keybinds settings + test |
| Operator scripts | `deploy/self-hosting/ns/` |

Fluxer is AGPL-3.0: keep this fork public so NS users can get its source.
