// @vitest-environment happy-dom
// SPDX-License-Identifier: AGPL-3.0-or-later

import {expect, test, vi} from 'vitest';

vi.mock('@lingui/core/macro', () => ({
	msg: (descriptor: unknown) => descriptor,
	t: (descriptor: unknown) => descriptor,
}));

vi.mock('@lingui/react/macro', () => ({
	Trans: () => null,
	useLingui: () => ({i18n: {_: (descriptor: {message?: string}) => descriptor.message ?? ''}}),
}));

const BOOTSTRAP_ENDPOINT = 'https://primary.test/api';

(globalThis.window as unknown as Record<string, unknown>).__FLUXER_BOOTSTRAP__ = {
	config: {
		releaseChannel: 'stable',
		bootstrapApiEndpoint: BOOTSTRAP_ENDPOINT,
		bootstrapApiPublicEndpoint: BOOTSTRAP_ENDPOINT,
	},
	instance: {
		api_code_version: Number.MAX_SAFE_INTEGER,
		endpoints: {
			api: BOOTSTRAP_ENDPOINT,
			api_client: BOOTSTRAP_ENDPOINT,
			api_public: BOOTSTRAP_ENDPOINT,
			gateway: 'wss://gateway.primary.test',
			media: 'https://media.primary.test',
			static_cdn: 'https://cdn.primary.test',
			marketing: 'https://primary.test',
			admin: 'https://admin.primary.test',
			invite: 'https://primary.test/invite',
			gift: 'https://primary.test/gift',
			webapp: 'https://app.primary.test',
			upload_relay: 'https://upload.primary.test',
		},
		captcha: {provider: 'none'},
		features: {
			voice_enabled: false,
			stripe_enabled: false,
			self_hosted: false,
			presigned_attachment_uploads: false,
			emails_enabled: false,
			phone_verification_enabled: false,
		},
		gif: {provider: 'klipy', display_name: 'Klipy', attribution_required: false},
		sso: {enabled: false, enforced: false, display_name: null, redirect_uri: ''},
		registration: {mode: 'open', admin_registration_urls_enabled: true},
		community: {single_community: false, single_community_guild_id: null, direct_messages_disabled: false},
		services: {gif_enabled: true, youtube_enabled: false, bluesky_enabled: false},
		limits: undefined,
		push: {public_vapid_key: null},
		app_public: {
			branding: {
				product_name: 'Fluxer',
				icon_url: null,
				symbol_url: null,
				logo_url: null,
				wordmark_url: null,
				favicon_url: null,
				theme_color: null,
			},
			setup: {configured: true, admin_url: null},
			legal: {terms_url: null, privacy_url: null},
			registration: {collect_date_of_birth: true},
		},
	},
};

const {default: Keybind, getDefaultKeybind, isKeybindCommand} = await import('@app/features/input/state/InputKeybind');

const labelI18n = {_: (descriptor: {message?: string}) => descriptor.message ?? ''} as unknown as Parameters<
	typeof getDefaultKeybind
>[1];

test('the soundboard keybind is no longer offered, since NS has no soundboard to toggle', () => {
	expect(Keybind.getDefaults().some((entry) => entry.action === 'voice_toggle_soundboard')).toBe(false);
	expect(getDefaultKeybind('voice_toggle_soundboard', labelI18n)).toBeNull();
});

test('ctrl or cmd + shift + B is no longer taken by a default shortcut', () => {
	const taken = Keybind.getDefaults().filter(
		(entry) => entry.combo.key.toLowerCase() === 'b' && entry.combo.ctrlOrMeta === true && entry.combo.shift === true,
	);
	expect(taken).toEqual([]);
});

test('a soundboard binding saved by an older client still parses as a known command', () => {
	expect(isKeybindCommand('voice_toggle_soundboard')).toBe(true);
	expect(Keybind.getActiveCombosForAction('voice_toggle_soundboard')).toEqual([]);
});
