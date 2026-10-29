#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Apply the NS customizations to an upstream Fluxer source tree.
#
#   bash deploy/self-hosting/ns/ns-apply.sh [REPO_ROOT]     # default: the current git repo
#   bash deploy/self-hosting/ns/ns-apply.sh --check         # change nothing; exit 1 if not fully applied
#
# Every edit is exact: the text to replace must occur exactly as often as expected,
# or the script stops and names the edit, before or after which nothing is half-done
# in that file. Running it twice is safe: an edit already in place is reported and skipped.
# ns-deploy.sh runs this on the upstream revision your server runs, so NS keeps
# working when upstream moves code around.
#
# NS settings: change them here, then redeploy.
NS_NAME='NS'
NS_DESCRIPTION='NS is a chat app for friends, groups and communities.'
NS_COLOR='#5865F2'   # main brand colour (hex), Discord-like blurple
NS_HUE=235           # the same colour as an HSL hue, 0-360
NS_SATURATION=86     # its HSL saturation, 0-100

set -euo pipefail

check_only=0
root=''
for arg in "$@"; do
	case "$arg" in
		--check) check_only=1 ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
		*) root="$arg" ;;
	esac
done
if [ -z "$root" ]; then
	root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo 'Not inside a git repository; pass the repo root.' >&2; exit 2; }
fi
cd "$root"
[ -f fluxer_app/package.json ] || { echo "$root does not look like the Fluxer/NS repository." >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo 'perl is required.' >&2; exit 2; }

applied=0
already=0
pending=0

# edit FILE MODE EXPECTED OLD NEW
#   MODE literal: OLD is plain text. MODE regex: OLD is a Perl regular expression.
#   EXPECTED: exact number of OLD occurrences required, or + for one or more.
# Already applied = OLD absent and NEW present.
edit() {
	local file="$1" mode="$2" expected="$3" old="$4" new="$5" status
	if [ ! -f "$file" ]; then
		echo "STOP: $file does not exist in this revision." >&2
		exit 3
	fi
	status=0
	NS_FILE="$file" NS_MODE="$mode" NS_EXPECTED="$expected" NS_OLD="$old" NS_NEW="$new" NS_CHECK="$check_only" perl -0777 -e '
		my ($file, $mode, $expected, $old, $new, $check) = @ENV{qw(NS_FILE NS_MODE NS_EXPECTED NS_OLD NS_NEW NS_CHECK)};
		open(my $fh, "<", $file) or die "cannot read $file: $!\n";
		local $/; my $text = <$fh>; close $fh;
		# An insertion keeps its anchor (NEW contains OLD): it is done once NEW is present.
		if ($mode eq "literal" && $new ne "" && index($new, $old) >= 0 && index($text, $new) >= 0) { exit 10; }
		my $pattern = $mode eq "regex" ? qr/$old/ : qr/\Q$old\E/;
		my $count = () = $text =~ /$pattern/g;
		if ($count == 0) {
			exit((index($text, $new) >= 0) ? 10 : 3);
		}
		if ($expected ne "+" && $count != $expected) { print STDERR "found $count times, expected $expected\n"; exit 4; }
		exit 11 if $check;
		$text =~ s/$pattern/$new/g;
		my $tmp = "$file.ns-apply-tmp";
		open(my $out, ">", $tmp) or die "cannot write $tmp: $!\n";
		print $out $text; close $out or die "cannot write $tmp: $!\n";
		my @st = stat($file); chmod($st[2] & 07777, $tmp);
		rename($tmp, $file) or die "cannot replace $file: $!\n";
		exit 0;
	' || status=$?
	case "$status" in
		0) applied=$((applied + 1)); printf 'applied  %s\n' "$file" ;;
		10) already=$((already + 1)); printf 'already  %s\n' "$file" ;;  # or, for a removal, already absent
		11) pending=$((pending + 1)); printf 'pending  %s\n' "$file" ;;
		3) printf 'STOP: an expected piece of upstream code was not found in %s:\n  %s\n' "$file" "$old" >&2; exit 3 ;;
		*) printf 'STOP: %s does not match what NS expects (see above). Edit:\n  %s\n' "$file" "$old" >&2; exit 4 ;;
	esac
}

# The one file that holds the brand family hue (it moved between upstream releases).
brand_hue_file() {
	local files
	files="$(grep -rlF -e 'brand: {hue: 242, saturation: 70,' -e "brand: {hue: $NS_HUE, saturation: $NS_SATURATION," \
		fluxer_app/scripts fluxer_app/src/features/theme --include='*.ts' 2>/dev/null | grep -v '\.test\.ts$' || true)"
	if [ "$(printf '%s' "$files" | grep -c .)" -ne 1 ]; then
		echo "STOP: expected exactly one file defining the brand hue, found: ${files:-none}" >&2
		exit 3
	fi
	printf '%s' "$files"
}

echo "== Product name: $NS_NAME"
edit fluxer_app/src/features/app/config/ProductConstants.ts literal 1 \
	"export const PRODUCT_NAME = 'Fluxer';" "export const PRODUCT_NAME = '$NS_NAME';"
edit fluxer_app/index.html literal 1 '<title>Fluxer</title>' "<title>$NS_NAME</title>"
edit fluxer_app/index.html regex 1 '<meta name="description" content="Fluxer [^"]*">' \
	"<meta name=\"description\" content=\"$NS_DESCRIPTION\">"
edit fluxer_app/index.html literal 1 'name="apple-mobile-web-app-title" content="Fluxer"' \
	"name=\"apple-mobile-web-app-title\" content=\"$NS_NAME\""
edit fluxer_app/scripts/build/rspack/static-files.mjs literal 2 "name: 'Fluxer'," "name: '$NS_NAME',"
edit fluxer_app/scripts/build/rspack/static-files.mjs regex 1 "'Fluxer is a free and open source[^']*'" "'$NS_DESCRIPTION'"
edit fluxer_desktop/electron-builder.config.cjs literal 1 "productName: 'Fluxer'," "productName: '$NS_NAME',"
edit fluxer_desktop/electron-builder.config.cjs literal 1 "artifactProductName: 'Fluxer'," "artifactProductName: '$NS_NAME',"

echo "== Brand colour: $NS_COLOR (hue $NS_HUE, saturation $NS_SATURATION)"
edit fluxer_app/index.html literal + '#4641D9' "$NS_COLOR"
edit fluxer_app/scripts/build/rspack/static-files.mjs literal + '#4641D9' "$NS_COLOR"
hue_file="$(brand_hue_file)"
edit "$hue_file" literal 1 'brand: {hue: 242, saturation: 70,' "brand: {hue: $NS_HUE, saturation: $NS_SATURATION,"

echo '== Wordmark: only the name Fluxer may draw the bundled Fluxer wordmark'
wordmark=fluxer_app/src/features/ui/components/icons/FluxerWordmark.tsx
edit "$wordmark" literal 1 'productName !== DEFAULT_APP_SHELL_BRANDING.productName' \
	'productName !== BUNDLED_WORDMARK_PRODUCT_NAME'
edit "$wordmark" literal 1 'interface FluxerWordmarkProps extends BrandSvgProps {' \
	"// The bundled wordmark assets spell this name, so only this product name may draw them.
const BUNDLED_WORDMARK_PRODUCT_NAME = 'Fluxer';

interface FluxerWordmarkProps extends BrandSvgProps {"
if [ "$(grep -c 'DEFAULT_APP_SHELL_BRANDING' "$wordmark")" -eq 1 ]; then
	# The import is now the only use left: drop it (the build type-checks unused imports).
	edit "$wordmark" literal 1 'import {DEFAULT_APP_SHELL_BRANDING, resolveAppShellBranding} from' 'import {resolveAppShellBranding} from'
fi

echo '== Soundboard: remove the keybind for a feature that does not exist'
edit fluxer_app/src/features/input/state/InputKeybind.ts literal 1 "		{
			action: 'voice_toggle_soundboard',
			label: i18n._(TOGGLE_THE_SOUNDBOARD_DESCRIPTOR),
			combo: {key: 'b', ctrlOrMeta: true, shift: true},
			assignable: true,
			section: 'voice_and_video',
		},
" ''
edit fluxer_app/src/features/input/state/InputKeybind.ts literal 1 "	TOGGLE_THE_SOUNDBOARD_DESCRIPTOR,
" ''
edit fluxer_app/src/features/input/state/input_keybind/shared.ts literal 1 "export const TOGGLE_THE_SOUNDBOARD_DESCRIPTOR = msg({
	message: 'Toggle the soundboard',
	comment: 'Keyboard shortcut action label shown in the shortcuts list and keybind editor. Keep short, sentence case.',
});
" ''
edit fluxer_app/src/features/user/components/modals/tabs/keybinds_tab/shared.ts literal 1 "		'voice_toggle_soundboard',
" ''

echo
if [ "$check_only" -eq 1 ]; then
	echo "Check: $already already applied, $pending still to apply."
	[ "$pending" -eq 0 ] || exit 1
else
	echo "Done: $applied applied, $already already in place."
fi
