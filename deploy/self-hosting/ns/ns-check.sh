#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# NS read-only health and safety report for a self-hosted stack.
#
# Run it from deploy/self-hosting (the folder holding docker-compose.yml and .env):
#   bash ns/ns-check.sh
#
# It changes nothing: no restarts, no pulls, no writes. It never prints a secret.
# For secret settings it prints only MISSING, EMPTY, PLACEHOLDER, SHORT or set.

set -uo pipefail

STACK_DIR="${1:-.}"
cd "$STACK_DIR" || {
	echo "Cannot enter $STACK_DIR" >&2
	exit 2
}
if [ ! -f docker-compose.yml ] || [ ! -f .env ]; then
	echo "Run this in the folder that holds docker-compose.yml and .env (deploy/self-hosting)." >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ns-lib.sh
. "$SCRIPT_DIR/ns-lib.sh"

section() { printf '\n== %s ==\n' "$1"; }

section 'Host'
printf 'CPU cores: %s\n' "$(nproc 2>/dev/null || echo '?')"
if command -v free >/dev/null 2>&1; then
	free -m | awk 'NR==2 {printf "RAM: %s MB total, %s MB available\n", $2, $7} /^Swap:/ {printf "Swap: %s MB total, %s MB used\n", $2, $3}'
fi
df -Ph . | awk 'NR==2 {printf "Disk here: %s free of %s (%s used)\n", $4, $2, $5}'
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
if [ -n "$docker_root" ]; then
	df -Ph "$docker_root" 2>/dev/null | awk 'NR==2 {printf "Disk for Docker data: %s free of %s (%s used)\n", $4, $2, $5}'
fi

section 'Docker'
docker version --format 'Docker engine: {{.Server.Version}}' 2>/dev/null || echo 'Docker engine: NOT REACHABLE'
docker compose version 2>/dev/null || echo 'docker compose: NOT FOUND'

project="$(ns_compose_project)"
printf 'Compose project: %s\n' "$project"

section 'Containers'
if ! docker compose ps --all --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null; then
	echo 'Could not list containers (is Docker running?).'
fi

section 'Running versions (what to pin NS against)'
printf '%-16s %-14s %-24s %-42s %s\n' SERVICE IMAGE_ID BUILD_VERSION REVISION IMAGE
for service in api worker gateway app-proxy media-proxy static-proxy admin; do
	cid="$(docker compose ps --all -q "$service" 2>/dev/null | head -n1)"
	if [ -z "$cid" ]; then
		printf '%-16s %s\n' "$service" '(no container)'
		continue
	fi
	image_ref="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"
	image_id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)"
	revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image_id" 2>/dev/null)"
	build_version="$(docker image inspect -f '{{index .Config.Labels "app.fluxer.build-version"}}' "$image_id" 2>/dev/null)"
	short_id="${image_id#sha256:}"
	printf '%-16s %-14s %-24s %-42s %s\n' "$service" "${short_id:0:12}" "${build_version:--}" "${revision:--}" "$image_ref"
done
echo 'Pin rule: NS must be built from the REVISION shown for api (ns-deploy.sh reads it for you).'

if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	section 'Stack files (git)'
	printf 'Commit: %s\n' "$(git -C . rev-parse HEAD)"
	printf 'Branch: %s\n' "$(git -C . rev-parse --abbrev-ref HEAD)"
	if [ -n "$(git -C . status --porcelain -- . 2>/dev/null)" ]; then
		echo 'Local changes in this folder: YES (git status lists them)'
	else
		echo 'Local changes in this folder: none'
	fi
fi

section 'Secrets in .env (values never shown)'
weak=0
for key in POSTGRES_PASSWORD MEILI_MASTER_KEY FLUXER_S3_SECRET_KEY FLUXER_SUDO_MODE_SECRET \
	FLUXER_CONNECTION_INITIATION_SECRET FLUXER_PROFILE_PSEUDONYM_SECRET FLUXER_GATEWAY_RPC_AUTH_TOKEN \
	FLUXER_ERLANG_COOKIE FLUXER_MEDIA_PROXY_SECRET_KEY FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64 \
	FLUXER_ADMIN_SECRET_KEY_BASE FLUXER_ADMIN_OAUTH_CLIENT_SECRET FLUXER_VAPID_PRIVATE_KEY LIVEKIT_API_SECRET; do
	state="$(ns_secret_state "$key" .env)"
	case "$state" in set) ;; *) weak=$((weak + 1)) ;; esac
	printf '%-48s %s\n' "$key" "$state"
done
if [ "$weak" -gt 0 ]; then
	echo "ACTION: $weak secret(s) above are not safely set. Per the operator docs (configuration.mdx):"
	echo '  - most values: openssl rand -hex 32'
	echo '  - FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64: openssl rand -base64 32'
	echo '  - FLUXER_VAPID_PUBLIC_KEY + FLUXER_VAPID_PRIVATE_KEY: a generated pair (npx web-push generate-vapid-keys)'
	echo '  WARNING: on an instance that already has data, changing POSTGRES_PASSWORD in .env does NOT change'
	echo '  the database password (it is only read on first start), so the stack would fail to connect.'
	echo '  Changing the VAPID pair breaks existing push subscriptions. Change secrets one at a time, after a backup.'
else
	echo 'All checked secrets are set.'
fi

section 'Security-relevant settings (non-secret values)'
show() {
	local key="$1" default="$2" value
	value="$(ns_env_get "$key" .env)"
	if [ -z "$value" ]; then
		printf '%-50s %s (default)\n' "$key" "$default"
	else
		printf '%-50s %s\n' "$key" "$value"
	fi
}
show FLUXER_IMAGE_TAG v1
show COMPOSE_FILE docker-compose.yml
show FLUXER_PUBLIC_SCHEME https
show FLUXER_MEDIA_PROXY_ATTACHMENT_SIGNATURE_MODE off
show FLUXER_MEDIA_PROXY_CORS_MODE off
show FLUXER_S3_READ_SIGNED true
show FLUXER_CLAMAV_ENABLED false
show FLUXER_BREACHED_PASSWORD_CHECK_ENABLED false
show FLUXER_EMAIL_ENABLED false
show FLUXER_TRUST_CLIENT_IP_HEADER true
show FLUXER_EDGE_TRUSTED_PROXIES private_ranges
show FLUXER_VALKEY_MAXMEMORY 192mb
show FLUXER_VALKEY_MAXMEMORY_POLICY noeviction
show FLUXER_LIVEKIT_ENABLED true
show FLUXER_LIVEKIT_USE_EXTERNAL_IP true
show FLUXER_STRIPE_ENABLED false
show FLUXER_PUSH_SERVICE_RELAY_CONSENT_ACCEPTED false
show FLUXER_APP_PRODUCT_NAME 'Fluxer (or the admin panel value)'
for key in FLUXER_DOMAIN FLUXER_LIVEKIT_NODE_IP FLUXER_PUBLIC_ORIGIN; do
	if [ -n "$(ns_env_get "$key" .env)" ]; then
		printf '%-50s set (value hidden)\n' "$key"
	else
		printf '%-50s not set\n' "$key"
	fi
done

section 'Memory per container'
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}' 2>/dev/null ||
	echo 'docker stats unavailable.'
limit_total_mb=0
for cid in $(docker compose ps -q 2>/dev/null); do
	bytes="$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)"
	limit_total_mb=$((limit_total_mb + ${bytes:-0} / 1048576))
done
printf 'Sum of container memory limits: %s MB\n' "$limit_total_mb"

section 'Valkey memory'
docker compose exec -T valkey valkey-cli INFO memory 2>/dev/null |
	tr -d '\r' | grep -E '^(used_memory_human|maxmemory_human|maxmemory_policy):' ||
	echo 'Valkey not reachable (stack down, or service renamed).'

section 'Data volumes'
docker volume ls --filter "label=com.docker.compose.project=$project" --format '{{.Name}}' 2>/dev/null ||
	echo 'Could not list volumes.'
echo 'Back up: <project>_postgres-data (via pg_dump) and <project>_seaweedfs-data (uploads). ns-backup.sh does both.'

section 'Errors in the last 30 minutes (counts only)'
for service in api app-proxy gateway media-proxy; do
	count="$(docker compose logs --no-color --since 30m "$service" 2>/dev/null | grep -ciE '"level":(50|60)|level=error|\berror\b' || true)"
	printf '%-14s %s lines mentioning an error\n' "$service" "${count:-0}"
done

printf '\nDone. This report contains no secret values and is safe to share.\n'
