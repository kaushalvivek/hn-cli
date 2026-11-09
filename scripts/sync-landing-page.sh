#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest=${1:-}

if [ -z "$dest" ]; then
  printf 'usage: %s /path/to/vivekkaushal.com\n' "$0" >&2
  exit 2
fi

if [ ! -f "$dest/public/index.html" ]; then
  printf 'error: %s does not look like a vivekkaushal.com checkout\n' "$dest" >&2
  exit 2
fi

mkdir -p "$dest/public/hn-cli/assets"
cp "$root/docs/index.html" "$dest/public/hn-cli/index.html"
cp "$root/docs/style.css" "$dest/public/hn-cli/style.css"
cp "$root/docs/landing.js" "$dest/public/hn-cli/landing.js"
cp "$root/docs/assets/logo.svg" "$dest/public/hn-cli/assets/logo.svg"
cp "$root/docs/assets/tui.svg" "$dest/public/hn-cli/assets/tui.svg"

printf 'synced landing page to %s/public/hn-cli\n' "$dest"
