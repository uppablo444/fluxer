#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build the NS web client from the EXACT upstream revision your server runs,
# switch the stack to it, check it is healthy, and roll back on any failure.
#
# Run it from deploy/self-hosting inside a git clone of your NS fork:
#   bash ns/ns-deploy.sh --dry-run     # resolve versions and apply NS commits, build nothing
#   bash ns/ns-deploy.sh               # build + switch + health check (auto-rollback on failure)
#   bash ns/ns-deploy.sh --rollback    # go back to the stock upstream client (keeps the NS image)
#
# Options:
#   --ns-ref REF       where the NS commits live (default: origin/ns/main)
#   --revision SHA     pin to this full upstream commit instead of reading the running api image
#   --upstream URL     upstream repository (default: https://github.com/fluxerapp/fluxer.git)
#   --dry-run          stop after preparing the pinned source tree
#   --keep-worktree    keep the build folder afterwards (for inspection)
#   --use-image IMAGE  skip the build and switch to IMAGE, which must carry the label
#                      ns.source=<pinned commit> (an image this script or CI built earlier)
#
# What it never does: touch your working tree or uncommitted changes (it builds in a
# separate git worktree), delete volumes or data, change any service except app-proxy,
# or guess a revision. When the running revision cannot be read, it stops and says why.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ns-lib.sh
. "$SCRIPT_DIR/ns-lib.sh"

ns_ref='origin/ns/main'
revision=''
upstream_url='https://github.com/fluxerapp/fluxer.git'
dry_run=0
keep_worktree=0
use_image=''
mode=deploy
OVERLAY='docker-compose.ns.yml'

while [ $# -gt 0 ]; do
	case "$1" in
		--ns-ref) ns_ref="${2:?--ns-ref needs a ref}"; shift 2 ;;
		--revision) revision="${2:?--revision needs a full commit id}"; shift 2 ;;
		--upstream) upstream_url="${2:?--upstream needs a URL}"; shift 2 ;;
		--dry-run) dry_run=1; shift ;;
		--keep-worktree) keep_worktree=1; shift ;;
		--use-image) use_image="${2:?--use-image needs an image name}"; shift 2 ;;
		--rollback) mode=rollback; shift ;;
		-h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
done

say() { printf '[ns-deploy] %s\n' "$*"; }
fail() { printf '[ns-deploy] STOPPED: %s\n' "$*" >&2; exit 1; }

[ -f docker-compose.yml ] && [ -f .env ] || fail 'Run this in deploy/self-hosting (the folder with docker-compose.yml and .env).'
stack_dir="$(pwd)"

# COMPOSE_FILE handling ------------------------------------------------------
compose_file_value() {
	local value
	value="$(ns_env_get COMPOSE_FILE .env)"
	printf '%s' "${value:-docker-compose.yml}"
}

# Write COMPOSE_FILE=<value> into .env, editing only that line (or appending it),
# after saving a timestamped copy of .env. Every other line is kept as it is.
set_compose_file() {
	local next="$1" stamp tmp
	stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	cp -p .env ".env.ns-backup-$stamp"
	if ns_env_has COMPOSE_FILE .env; then
		tmp="$(mktemp "$stack_dir/.env.ns-tmp.XXXXXX")"
		awk -v next_value="$next" '
			/^[ \t]*(export[ \t]+)?COMPOSE_FILE[ \t]*=/ { last = NR }
			{ lines[NR] = $0 }
			END {
				for (i = 1; i <= NR; i++) {
					if (i == last) print "COMPOSE_FILE=" next_value
					else print lines[i]
				}
			}
		' .env > "$tmp"
		chmod --reference=.env "$tmp" 2>/dev/null || true
		mv "$tmp" .env
	else
		printf '\n# Added by ns/ns-deploy.sh: the NS client overlay\nCOMPOSE_FILE=%s\n' "$next" >> .env
	fi
	say "COMPOSE_FILE is now: $next (previous .env saved as .env.ns-backup-$stamp)"
}

# Add the NS overlay as the LAST entry of COMPOSE_FILE, so it wins.
enable_overlay() {
	local current
	current="$(compose_file_value)"
	case ":$current:" in *":$OVERLAY:"*) return 0 ;; esac
	set_compose_file "$current:$OVERLAY"
}

# Remove the NS overlay from COMPOSE_FILE; the stock upstream client comes back.
disable_overlay() {
	local current next
	current="$(compose_file_value)"
	case ":$current:" in *":$OVERLAY:"*) ;; *) return 0 ;; esac
	next="$(printf '%s' "$current" | tr ':' '\n' | grep -vxF "$OVERLAY" | paste -sd: -)"
	set_compose_file "${next:-docker-compose.yml}"
}

wait_healthy() {
	local cid state
	for _ in $(seq 1 90); do
		cid="$(docker compose ps -q app-proxy 2>/dev/null | head -n1)"
		if [ -n "$cid" ]; then
			state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
			case "$state" in
				healthy) return 0 ;;
				unhealthy|exited|dead) return 1 ;;
			esac
		fi
		sleep 2
	done
	return 1
}

# --- rollback ----------------------------------------------------------------
if [ "$mode" = rollback ]; then
	docker info >/dev/null 2>&1 || fail 'Docker is not reachable.'
	disable_overlay
	docker compose up -d app-proxy
	if wait_healthy; then
		say 'Rollback done: app-proxy is healthy on the stock upstream client. The NS image is kept; redeploy any time.'
	else
		fail 'app-proxy is not healthy after the rollback. Read: docker compose logs app-proxy'
	fi
	exit 0
fi

# --- 1. repository -------------------------------------------------------------
command -v git >/dev/null 2>&1 || fail 'git is not installed.'
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'This folder is not inside a git clone of the NS repository.'

if ! git -C "$repo_root" remote get-url upstream >/dev/null 2>&1; then
	git -C "$repo_root" remote add upstream "$upstream_url"
	say "Added git remote upstream -> $upstream_url"
fi
say 'Fetching upstream main and the NS commits.'
git -C "$repo_root" fetch --quiet upstream main || fail 'Could not fetch upstream main.'
ns_remote="${ns_ref%%/*}"
if [ "$ns_remote" != "$ns_ref" ] && git -C "$repo_root" remote get-url "$ns_remote" >/dev/null 2>&1; then
	git -C "$repo_root" fetch --quiet "$ns_remote" || fail "Could not fetch $ns_remote."
fi
git -C "$repo_root" rev-parse --verify --quiet "$ns_ref^{commit}" >/dev/null || fail "NS ref $ns_ref does not exist."

# --- 2. the revision the server runs -----------------------------------------
build_version=''
if [ -z "$revision" ]; then
	docker info >/dev/null 2>&1 || fail 'Docker is not reachable, so the running revision cannot be read. Start the stack, or pass --revision.'
	revision="$(ns_running_revision)"
	build_version="$(ns_running_build_version)"
	if ! ns_is_full_sha "$revision" && [ -n "$build_version" ]; then
		say "The api image has no revision label; looking up release tag fluxer-api@$build_version."
		revision="$(git -C "$repo_root" ls-remote upstream "refs/tags/fluxer-api@$build_version" | awk '{print $1}' | head -n1)"
	fi
	if ! ns_is_full_sha "$revision"; then
		fail 'Could not read which source revision the running api was built from (no revision label, no matching release tag).
  If you built the server images yourself, pass that commit: bash ns/ns-deploy.sh --revision <full commit id>
  Nothing was changed.'
	fi
	say "Running api: revision $revision${build_version:+, build $build_version}"
else
	ns_is_full_sha "$revision" || fail '--revision must be a full 40-character commit id.'
	say "Pinning to the revision you gave: $revision"
fi
if ! git -C "$repo_root" cat-file -e "$revision^{commit}" 2>/dev/null; then
	git -C "$repo_root" fetch --quiet upstream "$revision" || fail "Upstream does not have commit $revision."
fi

# The NS commits: on the NS ref but not in upstream main, oldest first, no merges.
mapfile -t ns_commits < <(git -C "$repo_root" rev-list --reverse --no-merges "upstream/main..$ns_ref")
[ "${#ns_commits[@]}" -gt 0 ] || fail "No NS commits found on $ns_ref (compared with upstream/main)."
say "NS commits to apply on top (${#ns_commits[@]}):"
for c in "${ns_commits[@]}"; do
	printf '    %s\n' "$(git -C "$repo_root" log -1 --format='%h %s' "$c")"
done

# --- 3. pinned source tree in a separate worktree ------------------------------
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
short_rev="${revision:0:12}"
branch="ns/pinned-$short_rev-$stamp"
worktree="$repo_root/.ns-build/$stamp"
cleanup_worktree() {
	if [ "$keep_worktree" -eq 0 ] && [ -d "$worktree" ]; then
		git -C "$repo_root" cherry-pick --abort >/dev/null 2>&1 || true
		git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
	fi
}
trap cleanup_worktree EXIT
mkdir -p "$repo_root/.ns-build"
git -C "$repo_root" worktree add --quiet -b "$branch" "$worktree" "$revision" || fail 'Could not create the build worktree.'
for c in "${ns_commits[@]}"; do
	if ! git -C "$worktree" -c user.name='NS deploy' -c user.email='ns-deploy@localhost' cherry-pick -x "$c" >/dev/null 2>&1; then
		conflicts="$(git -C "$worktree" diff --name-only --diff-filter=U | sed 's/^/    /')"
		git -C "$worktree" cherry-pick --abort >/dev/null 2>&1 || true
		fail "NS commit $(git -C "$repo_root" log -1 --format='%h %s' "$c") does not apply cleanly on $short_rev.
  Conflicting files:
$conflicts
  The server keeps running the current client. Nothing was changed."
	fi
done
pinned_head="$(git -C "$worktree" rev-parse HEAD)"
say "Pinned NS source ready: branch $branch ($pinned_head)"

if [ "$dry_run" -eq 1 ]; then
	git -C "$repo_root" log --oneline -n "$((${#ns_commits[@]} + 1))" "$branch"
	say 'Dry run finished. Nothing was built or switched. The branch above stays for inspection.'
	exit 0
fi

# --- 4. build -----------------------------------------------------------------------
docker info >/dev/null 2>&1 || fail 'Docker is not reachable.'
if [ -n "$use_image" ]; then
	docker image inspect "$use_image" >/dev/null 2>&1 || fail "Image $use_image is not on this machine."
	image_source="$(docker image inspect -f '{{index .Config.Labels "ns.source"}}' "$use_image")"
	if [ "$image_source" != "$pinned_head" ]; then
		fail "Image $use_image was built from ${image_source:-an unknown commit}, not from the pinned source $pinned_head. Refusing to switch to it."
	fi
	image="$use_image"
	say "Using the existing image $image (built from the pinned source)."
else
docker buildx version >/dev/null 2>&1 || fail 'Docker BuildKit (buildx) is required by fluxer_app_proxy/Dockerfile.'
avail_mb="$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "${avail_mb:-0}" -lt 6000 ]; then
	say "WARNING: only ${avail_mb} MB of RAM available; the client build may need about 8 GB. Add swap if it gets killed."
fi
if [ -z "$build_version" ]; then
	build_version="$(ns_running_build_version 2>/dev/null || true)"
fi
ns_version="${build_version:-ns}-ns.${pinned_head:0:7}"
image="ns/app-proxy:${short_rev}-ns.${pinned_head:0:7}"
say "Building $image (this takes 20-60 minutes the first time)."
docker build \
	-f "$worktree/fluxer_app_proxy/Dockerfile" \
	--build-arg FLUXER_SELF_HOSTED=true \
	--build-arg BUNDLE_LOCAL_ASSETS=true \
	--build-arg PUBLIC_ASSET_BASE_URL= \
	--build-arg BUILD_VERSION="$ns_version" \
	--build-arg SOURCE_SHA="$pinned_head" \
	--label "ns.upstream-revision=$revision" \
	--label "ns.source=$pinned_head" \
	-t "$image" \
	"$worktree" || fail 'The build failed. The server keeps running the current client. Nothing was changed.'
fi

# --- 5. switch, with automatic rollback --------------------------------------------
previous_cid="$(docker compose ps -q app-proxy 2>/dev/null | head -n1)"
previous_image=none
if [ -n "$previous_cid" ]; then
	previous_image="$(docker inspect -f '{{.Config.Image}}' "$previous_cid")"
fi
overlay_backup=''
if [ -f "$OVERLAY" ]; then
	overlay_backup="$OVERLAY.ns-backup-$stamp"
	cp -p "$OVERLAY" "$overlay_backup"
fi
overlay_was_enabled=0
case ":$(compose_file_value):" in *":$OVERLAY:"*) overlay_was_enabled=1 ;; esac

# Put back exactly what ran before: the previous NS overlay, or the stock client.
restore_previous() {
	if [ -n "$overlay_backup" ] && [ "$overlay_was_enabled" -eq 1 ]; then
		cp -p "$overlay_backup" "$OVERLAY"
		say "Restored the previous NS overlay ($previous_image)."
	else
		disable_overlay
	fi
	docker compose up -d app-proxy || true
	wait_healthy || say 'WARNING: app-proxy is still not healthy after restoring. Read: docker compose logs app-proxy'
}

cat > "$OVERLAY" <<OVERLAY_EOF
# Written by ns/ns-deploy.sh on $stamp. Pins the NS web client.
# Upstream revision (matches the running api): $revision
# NS source commit: $pinned_head
# Previous app-proxy image: $previous_image
# Roll back to the stock client with: bash ns/ns-deploy.sh --rollback
services:
  app-proxy:
    image: $image
    pull_policy: never
OVERLAY_EOF
enable_overlay
if ! docker compose config --quiet; then
	say 'docker compose rejected the configuration after the change; restoring.'
	restore_previous
	fail 'The compose overlay was rejected. The previous client is back.'
fi
say 'Switching app-proxy to the NS client.'
docker compose up -d app-proxy
if ! wait_healthy; then
	say 'app-proxy did not become healthy. Restoring the previous client automatically.'
	restore_previous
	fail 'The NS client failed its health check and was rolled back. Read: docker compose logs app-proxy'
fi
if docker compose exec -T app-proxy curl -fsSL http://127.0.0.1:8080/ 2>/dev/null | grep -q '<title>NS</title>'; then
	say 'Health check passed and the page title is NS.'
else
	say 'WARNING: app-proxy is healthy but the page did not show the NS title. Check in a browser before relying on it.'
fi

say "Done. NS client $image is live, pinned to upstream $short_rev."
say 'Record of this deploy: the header of docker-compose.ns.yml.'
say 'Roll back any time with: bash ns/ns-deploy.sh --rollback'
