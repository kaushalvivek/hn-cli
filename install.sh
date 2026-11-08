#!/bin/sh
set -eu

REPO="kaushalvivek/hn-cli"
INSTALL_DIR="${HN_INSTALL_DIR:-$HOME/.local/bin}"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

[ "$(uname -s)" = "Darwin" ] || fail "hn currently ships prebuilt binaries for macOS only. Build from source: https://github.com/$REPO#from-source"

need curl
need tar
need shasum
need install
need mktemp

if [ -n "${HN_VERSION:-}" ]; then
  VERSION="${HN_VERSION#v}"
  TAG="v$VERSION"
  BASE_URL="https://github.com/$REPO/releases/download/$TAG"
  ASSET="hn-$TAG-macos-universal.tar.gz"
else
  BASE_URL="https://github.com/$REPO/releases/latest/download"
  ASSET="hn-macos-universal.tar.gz"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hn-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

say "hn installer"
say "  downloading $ASSET"

curl --proto '=https' --tlsv1.2 -fsSL "$BASE_URL/$ASSET" -o "$TMP_DIR/$ASSET" \
  || fail "could not download $ASSET"
curl --proto '=https' --tlsv1.2 -fsSL "$BASE_URL/checksums.txt" -o "$TMP_DIR/checksums.txt" \
  || fail "could not download checksums.txt"

HASH="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TMP_DIR/checksums.txt")"
[ -n "$HASH" ] || fail "no checksum found for $ASSET"

(
  cd "$TMP_DIR"
  printf '%s  %s\n' "$HASH" "$ASSET" | shasum -a 256 -c - >/dev/null
) || fail "checksum verification failed"

tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"
install -d "$INSTALL_DIR"
install -m 0755 "$TMP_DIR/hn" "$INSTALL_DIR/hn"

say "  installed to $INSTALL_DIR/hn"
say "  $("$INSTALL_DIR/hn" --version 2>/dev/null || true)"
say ""
say "Run \`hn\` to open Hacker News."

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    say ""
    say "Add $INSTALL_DIR to your PATH:"
    say "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac
