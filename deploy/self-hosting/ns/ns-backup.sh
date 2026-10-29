#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# NS backup with proof: dump the database, copy the uploads, then PROVE the
# backup by restoring it into a throwaway, network-less Postgres container.
#
# Run it from deploy/self-hosting:
#   bash ns/ns-backup.sh                      # database + uploads + restore drill
#   bash ns/ns-backup.sh --db-only            # database only, no downtime
#   bash ns/ns-backup.sh --offsite user@host:/backups/ns
#
# Options:
#   --dest DIR        where backups go (default: ./backups)
#   --db-only         skip the uploads copy (that copy stops the stack for a few minutes)
#   --offsite TARGET  rsync the finished backup to TARGET (user@host:/path) over SSH
#   --no-drill        skip the restore drill (not recommended)
#   --yes             do not ask before stopping the stack for the uploads copy
#
# Same steps as the official installer's backup (fluxer_docs/src/installer/install.sh):
# pg_dump in custom format with its header checked, then the uploads volume copied
# read-only while the stack is stopped. On any failure after the stop, the stack is
# started again. Nothing existing is deleted or overwritten; it only adds files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ns-lib.sh
. "$SCRIPT_DIR/ns-lib.sh"

HELPER_IMAGE='alpine:3.22'
dest='./backups'
db_only=0
offsite=''
drill=1
assume_yes=0

while [ $# -gt 0 ]; do
	case "$1" in
		--dest) dest="${2:?--dest needs a folder}"; shift 2 ;;
		--db-only) db_only=1; shift ;;
		--offsite) offsite="${2:?--offsite needs user@host:/path}"; shift 2 ;;
		--no-drill) drill=0; shift ;;
		--yes) assume_yes=1; shift ;;
		-h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

say() { printf '[ns-backup] %s\n' "$*"; }
fail() { printf '[ns-backup] FAILED: %s\n' "$*" >&2; exit 1; }

[ -f docker-compose.yml ] && [ -f .env ] || fail 'Run this in deploy/self-hosting (the folder with docker-compose.yml and .env).'
docker info >/dev/null 2>&1 || fail 'Docker is not reachable.'

pg_host="$(ns_env_get FLUXER_POSTGRES_HOST .env)"
if [ -n "$(ns_env_get FLUXER_POSTGRES_URL .env)" ] || { [ -n "$pg_host" ] && [ "$pg_host" != postgres ]; }; then
	fail 'This stack uses a database outside Docker Compose. Back it up with that database'"'"'s own tools.'
fi

kv_table="$(ns_env_get FLUXER_POSTGRES_KV_TABLE .env)"
kv_table="${kv_table:-fluxer_kv}"
printf '%s' "$kv_table" | grep -Eq '^[a-z_][a-z0-9_]*$' || fail "Unexpected KV table name: $kv_table"

project="$(ns_compose_project)"
[ -n "$project" ] || fail 'Could not work out the Compose project name.'

if [ -z "$(docker compose ps -q postgres 2>/dev/null)" ] ||
	[ "$(docker inspect -f '{{.State.Running}}' "$(docker compose ps -q postgres | head -n1)")" != true ]; then
	say 'Postgres is not running. Starting only Postgres for the dump.'
	docker compose up -d --wait postgres || fail 'Postgres did not start.'
fi
pg_cid="$(docker compose ps -q postgres | head -n1)"
pg_image="$(docker inspect -f '{{.Config.Image}}' "$pg_cid")"
pg_user="$(docker compose exec -T postgres sh -c 'printf %s "$POSTGRES_USER"')"
pg_db="$(docker compose exec -T postgres sh -c 'printf %s "$POSTGRES_DB"')"
[ -n "$pg_user" ] && [ -n "$pg_db" ] || fail 'Could not read the database role and name from the postgres container.'

psql_live() {
	docker compose exec -T postgres sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$1"' sh "$1"
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dest"
record="$(cd "$dest" && pwd)/ns-backup-$stamp"
umask 077
mkdir -m 700 "$record" || fail "Could not create $record."
say "Writing to $record"

# --- free space ------------------------------------------------------------
db_bytes="$(psql_live 'SELECT pg_database_size(current_database())')"
free_kb="$(df -Pk "$record" | awk 'NR==2 {print $4}')"
need_kb=$((db_bytes * 2 / 1024))
media_volume="${project}_seaweedfs-data"
copy_media=0
if [ "$db_only" -eq 0 ]; then
	if docker volume inspect "$media_volume" >/dev/null 2>&1; then
		copy_media=1
		media_kb="$(docker run --rm -v "$media_volume:/data:ro" "$HELPER_IMAGE" du -sk /data | awk 'NR==1 {print $1}')"
		need_kb=$((need_kb + media_kb * 12 / 10))
	else
		say "No volume named $media_volume, so uploads live elsewhere (external S3?). Skipping the uploads copy."
	fi
fi
if [ "$free_kb" -lt "$need_kb" ]; then
	fail "Not enough free space: about $((need_kb / 1024)) MB needed, $((free_kb / 1024)) MB free in $dest. Use --dest on a bigger disk."
fi

# --- 1. database dump ------------------------------------------------------
live_total="$(psql_live "SELECT count(*) FROM $kv_table")"
live_users="$(psql_live "SELECT count(*) FROM $kv_table WHERE table_name = 'users'")"
say "Live database: $live_total rows in $kv_table, $live_users user rows."
say 'Dumping the database (the stack keeps serving).'
if ! docker compose exec -T postgres sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' > "$record/fluxer.dump"; then
	fail 'pg_dump failed. Nothing was changed.'
fi
[ "$(head -c 5 "$record/fluxer.dump")" = PGDMP ] || fail 'The dump does not start with the Postgres custom-format header.'

# --- 2. dump readability ----------------------------------------------------
say 'Checking the dump with pg_restore --list.'
docker run --rm --network none -v "$record:/backup:ro" "$pg_image" pg_restore --list /backup/fluxer.dump > "$record/fluxer.dump.toc" ||
	fail 'pg_restore could not read the dump.'
grep -Eq "TABLE DATA public $kv_table " "$record/fluxer.dump.toc" ||
	fail "The dump has no data section for $kv_table."
say "Dump is readable: $(grep -c '' "$record/fluxer.dump.toc") catalogue entries."

# --- 3. uploads (stack stopped for a consistent copy) ----------------------
restart_stack() {
	say 'Starting the stack again.'
	docker compose up -d || say 'WARNING: docker compose up -d failed. Run it by hand and read docker compose logs.'
}
if [ "$copy_media" -eq 1 ]; then
	if [ "$assume_yes" -ne 1 ]; then
		printf '[ns-backup] The uploads copy stops NS for a few minutes. Continue? [y/N] '
		read -r answer || answer=''
		case "$answer" in y|Y|yes|YES) ;; *) say 'Uploads copy skipped. The database backup above is complete.'; copy_media=0 ;; esac
	fi
fi
if [ "$copy_media" -eq 1 ]; then
	say 'Stopping the stack for a consistent copy of the uploads.'
	docker compose stop || fail 'docker compose stop failed.'
	trap restart_stack EXIT
	say "Copying $media_volume."
	if ! docker run --rm -v "$media_volume:/data:ro" -v "$record:/backup" "$HELPER_IMAGE" tar czf /backup/seaweedfs-data.tgz -C /data .; then
		fail 'Copying the uploads failed (the stack is restarted).'
	fi
	trap - EXIT
	restart_stack
	chmod 600 "$record/seaweedfs-data.tgz"
	media_files="$(docker run --rm --network none -v "$record:/backup:ro" "$HELPER_IMAGE" \
		sh -c 'set -e; tar tzf /backup/seaweedfs-data.tgz > /tmp/list; grep -vc "/\$" /tmp/list || true')" ||
		fail 'The uploads archive is not readable.'
	say "Uploads archive is readable: $media_files files."
fi

# --- 4. configuration ------------------------------------------------------
cp .env "$record/env.backup"
chmod 600 "$record/env.backup"
for f in docker-compose*.yml ./*.compose.yml Caddyfile; do
	[ -f "$f" ] && cp "$f" "$record/"
done

# --- 5. restore drill --------------------------------------------------------
if [ "$drill" -eq 1 ]; then
	drill_name="ns-restore-drill-$stamp"
	cleanup_drill() { docker rm -f -v "$drill_name" >/dev/null 2>&1 || true; }
	trap cleanup_drill EXIT
	say 'Restore drill: restoring the dump into a throwaway Postgres with no network.'
	docker run -d --rm --name "$drill_name" --network none \
		-e POSTGRES_USER="$pg_user" -e POSTGRES_DB="$pg_db" -e POSTGRES_HOST_AUTH_METHOD=trust \
		"$pg_image" >/dev/null || fail 'Could not start the drill container.'
	ready=0
	for _ in $(seq 1 60); do
		if docker exec "$drill_name" pg_isready -U "$pg_user" -d "$pg_db" >/dev/null 2>&1 &&
			docker exec "$drill_name" psql -X -U "$pg_user" -d "$pg_db" -Atc 'SELECT 1' >/dev/null 2>&1; then
			ready=1
			break
		fi
		sleep 2
	done
	[ "$ready" -eq 1 ] || fail 'The drill database did not become ready.'
	if ! docker exec -i "$drill_name" pg_restore -U "$pg_user" -d "$pg_db" --no-owner --exit-on-error < "$record/fluxer.dump" > "$record/restore-drill.log" 2>&1; then
		fail "The restore drill FAILED. Details: $record/restore-drill.log. Do not rely on this backup."
	fi
	restored_total="$(docker exec "$drill_name" psql -X -U "$pg_user" -d "$pg_db" -Atc "SELECT count(*) FROM $kv_table")"
	restored_users="$(docker exec "$drill_name" psql -X -U "$pg_user" -d "$pg_db" -Atc "SELECT count(*) FROM $kv_table WHERE table_name = 'users'")"
	cleanup_drill
	trap - EXIT
	[ "${restored_total:-0}" -gt 0 ] || fail 'The restored database is empty.'
	say "Restore drill PASSED: $restored_total rows restored ($live_total live before the dump), $restored_users user rows ($live_users live)."
	printf 'restore drill passed %s: %s rows (live %s), %s user rows (live %s)\n' \
		"$stamp" "$restored_total" "$live_total" "$restored_users" "$live_users" > "$record/RESTORE-DRILL-PASSED"
fi

# --- 6. checksums and off-machine copy ---------------------------------------
(cd "$record" && sha256sum -- * > SHA256SUMS)
say 'Checksums written to SHA256SUMS.'

if [ -n "$offsite" ]; then
	command -v rsync >/dev/null 2>&1 || fail 'rsync is not installed (apt install rsync).'
	say "Copying off this machine to $offsite"
	rsync -a --checksum "$record" "$offsite/" || fail 'Off-machine copy failed. The local backup is still complete.'
	say 'Off-machine copy done.'
else
	say 'WARNING: this backup is only on this machine. Copy the whole folder somewhere else (or rerun with --offsite).'
fi

say "Backup complete: $record"
say 'It contains env.backup with every secret: keep it as private as the server.'
