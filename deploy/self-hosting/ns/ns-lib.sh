# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=bash
# Shared helpers for the NS operator scripts. Sourced, never run directly.
# Nothing here prints a secret value.

# The value of KEY in a dotenv file, as Docker Compose reads it: the last
# uncommented assignment wins, surrounding quotes are removed, and an unquoted
# value loses a trailing " # comment". Prints nothing when KEY is absent.
ns_env_get() {
	local key="$1" file="$2"
	[ -f "$file" ] || return 0
	awk -v key="$key" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/^export[ \t]+/, "", line)
			if (line ~ /^#/) next
			eq = index(line, "=")
			if (eq == 0) next
			name = substr(line, 1, eq - 1)
			sub(/[ \t]+$/, "", name)
			if (name != key) next
			value = substr(line, eq + 1)
			sub(/^[ \t]+/, "", value)
			first = substr(value, 1, 1)
			if ((first == "\"" || first == "\x27") && length(value) >= 2) {
				rest = substr(value, 2)
				close_at = index(rest, first)
				if (close_at > 0) value = substr(rest, 1, close_at - 1)
			} else {
				hash = index(value, " #")
				if (hash > 0) value = substr(value, 1, hash - 1)
				sub(/[ \t\r]+$/, "", value)
			}
			found = value
			seen = 1
		}
		END { if (seen) printf "%s", found }
	' "$file"
}

# 0 when KEY has an uncommented assignment in the file, even an empty one.
ns_env_has() {
	local key="$1" file="$2"
	[ -f "$file" ] || return 1
	grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file"
}

# MISSING, EMPTY, PLACEHOLDER, SHORT (under 16 characters) or set.
ns_secret_state() {
	local key="$1" file="$2" value
	if ! ns_env_has "$key" "$file"; then
		echo MISSING
		return 0
	fi
	value="$(ns_env_get "$key" "$file")"
	if [ -z "$value" ]; then
		echo EMPTY
	elif printf '%s' "$value" | grep -qiE 'change_?me'; then
		echo PLACEHOLDER
	elif [ "${#value}" -lt 16 ]; then
		echo SHORT
	else
		echo set
	fi
}

# The Compose project name: from a running container's label, then the
# compose file's top-level name, then the folder name (Compose's own fallback).
ns_compose_project() {
	local cid name
	cid="$(docker compose ps -q 2>/dev/null | head -n1)"
	if [ -n "$cid" ]; then
		name="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null)"
		if [ -n "$name" ]; then
			printf '%s\n' "$name"
			return 0
		fi
	fi
	name="$(ns_env_get COMPOSE_PROJECT_NAME .env)"
	if [ -n "$name" ]; then
		printf '%s\n' "$name"
		return 0
	fi
	name="$(awk '/^name:[ \t]*/ {sub(/^name:[ \t]*/, ""); gsub(/["\x27 \t\r]/, ""); print; exit}' docker-compose.yml 2>/dev/null)"
	if [ -n "$name" ]; then
		printf '%s\n' "$name"
		return 0
	fi
	basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
	printf '\n'
}

# The source revision the running api container was built from, or nothing.
ns_running_revision() {
	local cid image_id
	cid="$(docker compose ps -q api 2>/dev/null | head -n1)"
	[ -n "$cid" ] || return 0
	image_id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)"
	[ -n "$image_id" ] || return 0
	docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image_id" 2>/dev/null
}

# The build version (CalVer) label of the running api container, or nothing.
ns_running_build_version() {
	local cid image_id
	cid="$(docker compose ps -q api 2>/dev/null | head -n1)"
	[ -n "$cid" ] || return 0
	image_id="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)"
	[ -n "$image_id" ] || return 0
	docker image inspect -f '{{index .Config.Labels "app.fluxer.build-version"}}' "$image_id" 2>/dev/null
}

# 0 when the argument is a full 40-character hexadecimal git commit id.
ns_is_full_sha() {
	printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}
