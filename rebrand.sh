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
