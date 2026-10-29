# Rebrand: NS

NS is this Fluxer fork. Two layers make it NS:

| Layer | What | How |
| --- | --- | --- |
| Instance branding | Logos, favicon, name and colour that the server sends to every client | Server config, no rebuild: see below |
| Code | Default name NS, blurple `#5865F2`, install name, desktop title bar, removed dead keybind | `deploy/self-hosting/ns/ns-apply.sh`, built and deployed by `ns-deploy.sh`: see [NS-RUNBOOK.md](NS-RUNBOOK.md) |

The code layer used to be a manual `rebrand.sh` plus a hand-run `docker build`. Both are
replaced by `ns-apply.sh` (exact, verified edits that also work on newer upstream releases)
and `ns-deploy.sh` (builds against the exact revision the server runs, with rollback).

> Fluxer is **AGPL-3.0**: keep this fork public so NS users can get its source. The Fluxer
> logos are CC BY-SA 4.0; replacing them is what this page is for.

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

Hard-refresh the browser (`Ctrl+Shift+R`). The name, logo and favicon should now be yours. The page title and the installed-app name say NS once the NS client is deployed (code layer).

---

## Code layer

See [NS-RUNBOOK.md](NS-RUNBOOK.md). To change the name or colour, edit the settings at the
top of `deploy/self-hosting/ns/ns-apply.sh`, commit, push, and run `bash ns/ns-deploy.sh` on
the server.

## Optional: the last 13 "Fluxer" texts

A few strings name Fluxer literally instead of using the product name. Find them:

```bash
grep -rn "Fluxer" fluxer_app/src --include=*.tsx --include=*.ts | grep -v "test\|import\|Fluxer[A-Z]\|fluxer"
```

To change one, edit the text in the `.tsx` file, then run `pnpm i18n:refresh` from the repo root so the translation files follow. These are rare messages (update errors, an old font option), so you can leave them for later.

---
