// @vitest-environment happy-dom
// SPDX-License-Identifier: AGPL-3.0-or-later

import {renderToStaticMarkup} from 'react-dom/server';
import {afterEach, expect, test, vi} from 'vitest';

interface TestBranding {
	product_name: string;
	icon_url: string | null;
	symbol_url: string | null;
	logo_url: string | null;
	wordmark_url: string | null;
	favicon_url: string | null;
	theme_color: string | null;
}

let snapshot: {appPublic: {branding: TestBranding}} | null = null;

vi.mock('@lingui/core/macro', () => ({msg: (descriptor: unknown) => descriptor}));
vi.mock('@lingui/react/macro', () => ({
	useLingui: () => ({
		i18n: {
			_: (descriptor: {message?: string}, values?: {productName?: string}) =>
				(descriptor.message ?? '').replace('{productName}', values?.productName ?? ''),
		},
	}),
}));
vi.mock('@app/features/app/state/RuntimeConfig', () => ({default: {getSnapshotOrNull: () => snapshot}}));
vi.mock('@app/media/images/fluxer-wordmark.svg?react', () => ({default: () => <svg data-bundled="default" />}));
vi.mock('@app/media/images/fluxer-logo-wordmark-monochrome.svg?react', () => ({
	default: () => <svg data-bundled="monochrome" />,
}));

const {FluxerWordmark} = await import('@app/features/ui/components/icons/FluxerWordmark');
const {PRODUCT_NAME} = await import('@app/features/app/config/ProductConstants');

function branding(overrides: Partial<TestBranding>): {appPublic: {branding: TestBranding}} {
	return {
		appPublic: {
			branding: {
				product_name: PRODUCT_NAME,
				icon_url: null,
				symbol_url: null,
				logo_url: null,
				wordmark_url: null,
				favicon_url: null,
				theme_color: null,
				...overrides,
			},
		},
	};
}

afterEach(() => {
	snapshot = null;
});

test('the default NS product name draws its name as text, never the bundled Fluxer wordmark', () => {
	expect(PRODUCT_NAME).not.toBe('Fluxer');
	for (const value of [null, branding({})]) {
		snapshot = value;
		const markup = renderToStaticMarkup(<FluxerWordmark />);
		expect(markup).not.toContain('data-bundled');
		expect(markup).toContain(`>${PRODUCT_NAME}</span>`);
		expect(markup).toContain(`aria-label="${PRODUCT_NAME} wordmark"`);
	}
});

test('the monochrome variant also draws the NS name as text', () => {
	snapshot = branding({});
	const markup = renderToStaticMarkup(<FluxerWordmark variant="monochrome" />);
	expect(markup).not.toContain('data-bundled');
	expect(markup).toContain(`>${PRODUCT_NAME}</span>`);
});

test('an instance named Fluxer keeps the bundled wordmark assets', () => {
	snapshot = branding({product_name: 'Fluxer'});
	expect(renderToStaticMarkup(<FluxerWordmark />)).toContain('data-bundled="default"');
	expect(renderToStaticMarkup(<FluxerWordmark variant="monochrome" />)).toContain('data-bundled="monochrome"');
});

test('a configured wordmark URL wins over the product name', () => {
	snapshot = branding({wordmark_url: 'https://chat.example.com/web/wordmark.svg'});
	const markup = renderToStaticMarkup(<FluxerWordmark />);
	expect(markup).toContain('src="https://chat.example.com/web/wordmark.svg"');
	expect(markup).toContain(`alt="${PRODUCT_NAME} wordmark"`);
	expect(markup).not.toContain('data-bundled');
});

test('another custom product name draws as text', () => {
	snapshot = branding({product_name: 'Example Chat'});
	const markup = renderToStaticMarkup(<FluxerWordmark />);
	expect(markup).toContain('>Example Chat</span>');
	expect(markup).not.toContain('data-bundled');
});
