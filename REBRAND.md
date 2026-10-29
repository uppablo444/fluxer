# Rebrand Fluxer and host your own client

How this fork turns into **your** chat app (your name, logo, colours) running on your own server.

There are two layers. Do them in order. Layer 1 needs no code and no rebuild. Layer 2 changes the code and needs you to build your own client image.

| Layer | What changes | Rebuild? | Time |
| --- | --- | --- | --- |
| 1. Instance branding | Name, logos, favicon, theme colour, as users see them in the app | No, just `.env` + restart | 15 min |
| 2. Code rebrand | The defaults baked into the client: page title, installed-app name, UI colour scheme, built-in logos | Yes, build the `app-proxy` image | 1–2 h (the first build is slow) |

> Fluxer is **AGPL-3.0**. If people use your modified client over the network, you must give them its source code. Keeping your fork public on GitHub (`github.com/uppablo444/fluxer`) and linking it somewhere in your app is enough. The Fluxer logos are CC BY-SA 4.0. You are replacing them, so this only matters if you keep any of them.

---

## Every file you need to touch

### Layer 1: config (on the server)

| File | What to set |
| --- | --- |
| `deploy/self-hosting/.env` | `FLUXER_APP_PRODUCT_NAME`, `FLUXER_APP_LOGO_URL`, `FLUXER_APP_ICON_URL`, `FLUXER_APP_SYMBOL_URL`, `FLUXER_APP_WORDMARK_URL`, `FLUXER_APP_FAVICON_URL`, `FLUXER_APP_THEME_COLOR`, `FLUXER_PASSKEY_RP_NAME`, `FLUXER_EMAIL_FROM_NAME` |
| `deploy/self-hosting/branding/web/` (new folder) | Your own favicon and app icons, which replace Fluxer's |
| `deploy/self-hosting/docker-compose.custom.yml` (new file) | Mounts that folder, and later points to your own client image |

### Layer 2: code (in the repo)

| # | File | What's in it | Changed by `rebrand.sh` |
| --- | --- | --- | --- |
| 1 | `fluxer_app/src/features/app/config/ProductConstants.ts` | `PRODUCT_NAME = 'Fluxer'`, the fallback name used everywhere in the UI (180+ texts use it) | ✅ |
| 2 | `fluxer_app/index.html` | `<title>`, the description, the iOS home-screen title, and the `#4641D9` theme colour (×3) | ✅ |
| 3 | `fluxer_app/scripts/build/rspack/static-files.mjs` | The PWA `manifest.json` (installed-app name, short name, description, `theme_color`) and the Windows tile colour | ✅ |
| 4 | `fluxer_app/scripts/GenerateColorSystem.ts` | Line ~300, `brand: {hue: 242, saturation: 70}`: the purple used for every button, link and highlight | ✅ |
| 5 | `fluxer_desktop/electron-builder.config.cjs` | Desktop app `productName` (only if you build the desktop app) | ✅ |
| 6 | `fluxer_app/src/media/images/fluxer-logo-color.svg` | Built-in logo | ❌ Replace the file with yours, same name |
| 7 | `fluxer_app/src/media/images/fluxer-wordmark.svg` | Built-in wordmark (logo + name) | ❌ Replace |
| 8 | `fluxer_app/src/media/images/fluxer-logo-wordmark-monochrome.svg` | Single-colour wordmark | ❌ Replace |
| 9 | `fluxer_static/web/*.png`, `favicon.ico` | Favicons and app icons | ❌ Handled by the Layer 1 folder instead, so no rebuild is needed |
| 10 | `fluxer_desktop/build_resources/icons-stable/*.png` | Desktop app icons, 16 to 1024 px | ❌ Replace (desktop only) |
| 11 | `fluxer_app/src/features/i18n/locales/*/messages.po` | 13 texts that still say "Fluxer" literally (update warnings, the "Fluxer Sans" font option…) | ❌ Optional, see the end |

Files 6 to 8 only show when no logo URL is set in Layer 1. With Layer 1 done, you can skip them.

You don't need to touch anything else. The app reads the name and logos at runtime from the instance config, which is why Layer 1 already covers most of it.

---

## Layer 1: branding without rebuilding

Do this on the server (over VS Code SSH), in the folder you run `docker compose` from: `deploy/self-hosting/`.

### 1. Prepare your images

Make these files. PNGs need a square, transparent background.

| File | Size |
| --- | --- |
| `favicon.ico` | 16+32 px multi-size |
| `favicon-16x16.png` | 16×16 |
| `favicon-32x32.png` | 32×32 |
| `apple-touch-icon.png` | 180×180 |
| `android-chrome-192x192.png` | 192×192 |
| `android-chrome-512x512.png` | 512×512 |
| `mstile-150x150.png` | 150×150 |
| `logo.svg` | Your symbol (the icon alone) |
| `wordmark.svg` | Symbol + name, horizontal |

Generate all the PNG sizes from one 512 px image at https://realfavicongenerator.net.

Put **all** of them in `deploy/self-hosting/branding/web/`. The folder replaces Fluxer's `/web` folder completely, so a missing file shows up as a broken icon.

### 2. Mount the folder

Create `deploy/self-hosting/docker-compose.custom.yml`:

```yaml
services:
  static-proxy:
    volumes:
      - ./branding/web:/srv/fluxer-static/web:ro
```

Your files are now served at `https://YOUR-DOMAIN/web/...`, the same place Fluxer's were.

### 3. Edit `.env`

```env
# Load your custom file on top of the official one.
# If you already have a COMPOSE_FILE line (proxy or tunnel), add :docker-compose.custom.yml at the END of it instead.
COMPOSE_FILE=docker-compose.yml:docker-compose.custom.yml

FLUXER_APP_PRODUCT_NAME=NS
FLUXER_APP_ICON_URL=https://YOUR-DOMAIN/web/android-chrome-512x512.png
FLUXER_APP_SYMBOL_URL=https://YOUR-DOMAIN/web/logo.svg
FLUXER_APP_LOGO_URL=https://YOUR-DOMAIN/web/logo.svg
FLUXER_APP_WORDMARK_URL=https://YOUR-DOMAIN/web/wordmark.svg
FLUXER_APP_FAVICON_URL=https://YOUR-DOMAIN/web/favicon-32x32.png
FLUXER_APP_THEME_COLOR=#5865F2
FLUXER_PASSKEY_RP_NAME=NS
FLUXER_EMAIL_FROM_NAME=NS
```

Replace `YOUR-DOMAIN` with your real `FLUXER_DOMAIN` value.

> ⚠️ **The admin dashboard wins over `.env`.** If you went through the setup wizard, the branding you chose there is saved in the database. So after editing `.env`, also open `https://YOUR-DOMAIN/admin` → **Instance Config** → branding, and put the same values there (or clear the fields so `.env` applies). The quickest route is to set them there directly.

### 4. Apply

```bash
cd deploy/self-hosting
docker compose up -d
```

Hard-refresh the browser (`Ctrl+Shift+R`). The name, logo and favicon should now be yours. The page title and the installed-app name still say "Fluxer" until Layer 2.

---

## Layer 2: change the code and host your own client

### 1. Edit the code

From the repo root (on Windows, use **Git Bash** in VS Code, not PowerShell):

1. Open `rebrand.sh` and set `NAME`, `DESC`, `COLOR`, `HUE` and `SAT` at the top.
   - To get the HSL values, paste your hex colour into https://colorpicker.me. It shows `hsl(H, S%, L%)`: `HUE = H` and `SAT = S`.
2. Run it:
   ```bash
   bash rebrand.sh
   git diff --stat      # should show the 5 files above
   ```
3. Replace logo files 6 to 8 with your own SVGs, keeping the same file names.

Then save it to your fork:

```bash
git add -A
git commit -m "Rebrand to NS"
git push
```

### 2. Get the code onto the server

Over VS Code SSH, in the server's clone:

```bash
git pull
```

(Or do steps 1–2 directly on the server and skip the push/pull.)

### 3. Build your client image (on the server)

From the **repo root** on the server:

```bash
docker build \
  -f fluxer_app_proxy/Dockerfile \
  --build-arg FLUXER_SELF_HOSTED=true \
  --build-arg BUNDLE_LOCAL_ASSETS=true \
  --build-arg PUBLIC_ASSET_BASE_URL= \
  -t ns/app-proxy:1 \
  .
```

- These are the same settings Fluxer's own self-hosted image uses (from `.github/workflows/build-app-proxy-self-hosted.yaml`). `PUBLIC_ASSET_BASE_URL=` must stay empty, or the client loads files from Fluxer's CDN instead of your server.
- The first build compiles Rust, WebAssembly and the whole web app: expect **20–60 minutes**, ~8 GB of RAM and ~15 GB of disk. A laptop with less RAM can run out of memory. If the build gets "Killed", add swap or close other things on the laptop.
- Bump the tag each time you rebuild (`:2`, `:3`…), so you can roll back.

### 4. Use your image

Add `app-proxy` to `deploy/self-hosting/docker-compose.custom.yml`:

```yaml
services:
  static-proxy:
    volumes:
      - ./branding/web:/srv/fluxer-static/web:ro
  app-proxy:
    image: ns/app-proxy:1
    pull_policy: never
```

`pull_policy: never` stops `docker compose pull` from trying to download your local image from the internet.

```bash
cd deploy/self-hosting
docker compose up -d app-proxy
docker compose ps app-proxy        # wait until it says (healthy)
```

Hard-refresh the browser. The tab title, colours and installed-app name are now yours.

### 5. Roll back if something breaks

Comment out the `app-proxy:` block in `docker-compose.custom.yml`, then run `docker compose up -d app-proxy`. You're back on the official Fluxer client and nothing else changes.

---

## Updating later

1. Pull Fluxer's changes into your fork. On GitHub, use **Sync fork**, or run `git remote add upstream https://github.com/fluxerapp/fluxer.git` once, then `git pull upstream main`.
2. Fix conflicts in the 5 rebranded files if any (usually there are none). Running `rebrand.sh` again is safe.
3. Rebuild with a new tag, update the tag in `docker-compose.custom.yml`, and run `docker compose up -d app-proxy`.

Your changes all live in `docker-compose.custom.yml`, `.env` and `branding/`, so an upgrade that replaces `docker-compose.yml` doesn't wipe them.

> Keep your client and server versions close. The client warns when the server runs a newer version than it does. Rebuild your client whenever you upgrade the server images (`FLUXER_IMAGE_TAG`).

---

## Optional: the last 13 "Fluxer" texts

A few strings name Fluxer literally instead of using the product name. Find them:

```bash
grep -rn "Fluxer" fluxer_app/src --include=*.tsx --include=*.ts | grep -v "test\|import\|Fluxer[A-Z]\|fluxer"
```

To change one, edit the text in the `.tsx` file, then run `pnpm i18n:refresh` from the repo root so the translation files follow. These are rare messages (update errors, an old font option), so you can leave them for later.

---

## `rebrand.sh`

The script is saved next to this file in the repo root. Here is a copy:

```bash
#!/usr/bin/env bash
# Run from the root of the fluxer repo:  bash rebrand.sh
set -euo pipefail

NAME="NS"                  # your app name
DESC="NS is a chat app for friends, groups and communities."
COLOR="#5865F2"                # your main brand colour (hex)
HUE=235                        # same colour as an HSL hue, 0-360
SAT=86                         # its HSL saturation, 0-100

[ -f fluxer_app/index.html ] || { echo "Run this from the fluxer repo root"; exit 1; }

# 1. Default product name compiled into the web app
sed -i "s/^export const PRODUCT_NAME = 'Fluxer';/export const PRODUCT_NAME = '$NAME';/" \
  fluxer_app/src/features/app/config/ProductConstants.ts

# 2. Page title, description, home-screen title, browser theme colour
sed -i -e "s#<title>Fluxer</title>#<title>$NAME</title>#" \
  -e "s#<meta name=\"description\" content=\"[^\"]*\">#<meta name=\"description\" content=\"$DESC\">#" \
  -e "s#content=\"Fluxer\">#content=\"$NAME\">#" \
  -e "s/#4641D9/$COLOR/g" \
  fluxer_app/index.html

# 3. PWA manifest (installed-app name) and Windows tile colour
sed -i -e "s/name: 'Fluxer',/name: '$NAME',/" \
  -e "s/short_name: 'Fluxer',/short_name: '$NAME',/" \
  -e "s/'Fluxer is a free and open source[^']*'/'$DESC'/" \
  -e "s/#4641D9/$COLOR/g" \
  fluxer_app/scripts/build/rspack/static-files.mjs

# 4. Brand colour used across the whole UI (buttons, links, highlights)
sed -i "s/brand: {hue: 242, saturation: 70,/brand: {hue: $HUE, saturation: $SAT,/" \
  fluxer_app/scripts/GenerateColorSystem.ts

# 5. Desktop app name (only matters if you build the Electron app)
sed -i -e "s/productName: 'Fluxer',/productName: '$NAME',/" \
  -e "s/artifactProductName: 'Fluxer',/artifactProductName: '$NAME',/" \
  fluxer_desktop/electron-builder.config.cjs

echo "Done. Review with: git diff --stat"
```

Don't use `'`, `/` or `#` in `NAME` or `DESC`, because they break the `sed` commands.
