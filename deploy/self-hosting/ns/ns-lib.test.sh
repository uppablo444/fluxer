#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Self-check for ns-lib.sh. Needs no Docker. Run: bash ns/ns-lib.test.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ns-lib.sh
. "$SCRIPT_DIR/ns-lib.sh"

failures=0
check() {
	local name="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		printf 'ok   %s\n' "$name"
	else
		printf 'FAIL %s: expected [%s] got [%s]\n' "$name" "$expected" "$actual"
		failures=$((failures + 1))
	fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
env_file="$tmp/.env"
cat > "$env_file" <<'EOF'
# a comment
PLAIN=hello
QUOTED="with spaces # not a comment"
SINGLE='single quoted'
INLINE=value # trailing comment
REPEATED=first
REPEATED=second
#COMMENTED=nope
EMPTY=
PLACEHOLDER=CHANGE_ME
SHORTSECRET=abc123
LONGSECRET=0123456789abcdef0123456789abcdef
  export EXPORTED=yes
SPACED = spaced value
CRLF=windows
EOF
printf 'CRLF2=windows\r\n' >> "$env_file"

check 'plain value' hello "$(ns_env_get PLAIN "$env_file")"
check 'double quotes keep a hash' 'with spaces # not a comment' "$(ns_env_get QUOTED "$env_file")"
check 'single quotes' 'single quoted' "$(ns_env_get SINGLE "$env_file")"
check 'inline comment dropped' value "$(ns_env_get INLINE "$env_file")"
check 'last assignment wins' second "$(ns_env_get REPEATED "$env_file")"
check 'commented line ignored' '' "$(ns_env_get COMMENTED "$env_file")"
check 'export prefix' yes "$(ns_env_get EXPORTED "$env_file")"
check 'spaces around equals' 'spaced value' "$(ns_env_get SPACED "$env_file")"
check 'carriage return stripped' windows "$(ns_env_get CRLF2 "$env_file")"
check 'absent key' '' "$(ns_env_get NOPE "$env_file")"

check 'state missing' MISSING "$(ns_secret_state NOPE "$env_file")"
check 'state commented counts as missing' MISSING "$(ns_secret_state COMMENTED "$env_file")"
check 'state empty' EMPTY "$(ns_secret_state EMPTY "$env_file")"
check 'state placeholder' PLACEHOLDER "$(ns_secret_state PLACEHOLDER "$env_file")"
check 'state short' SHORT "$(ns_secret_state SHORTSECRET "$env_file")"
check 'state set' set "$(ns_secret_state LONGSECRET "$env_file")"

check 'full sha accepted' 0 "$(ns_is_full_sha 70fd9e633f00000000000000000000000000abcd && echo 0 || echo 1)"
check 'short sha rejected' 1 "$(ns_is_full_sha 70fd9e6 && echo 0 || echo 1)"
check 'empty rejected' 1 "$(ns_is_full_sha '' && echo 0 || echo 1)"

if [ "$failures" -gt 0 ]; then
	echo "$failures check(s) failed"
	exit 1
fi
echo 'all checks passed'
