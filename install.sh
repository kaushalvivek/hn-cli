#!/bin/sh
set -eu

REPO="kaushalvivek/hn-cli"
INSTALL_DIR="${HN_INSTALL_DIR:-${HOME:-}/.local/bin}"

usage() {
  cat <<'EOF'
Install hn from GitHub releases.

Usage:
  sh install.sh

Environment:
  HN_VERSION      Release version to install (default: latest)
  HN_INSTALL_DIR  Install directory (default: ~/.local/bin)

Linux users can also install a native package:
  Debian/Ubuntu  hn_<version>_<arch>.deb
  Fedora/RHEL    hn-<version>-1.<arch>.rpm
  Arch           hn-<version>-1-<arch>.pkg.tar.zst
  Alpine         hn_<version>_<arch>.apk
EOF
}

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

download() {
  url="$1"
  destination="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$destination" "$url"
  else
    fail "curl or wget is required"
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    fail "unknown argument: $1 (use --help)"
    ;;
esac

[ -n "${HOME:-}" ] || [ -n "${HN_INSTALL_DIR:-}" ] ||
  fail "HOME is not set; set HN_INSTALL_DIR to a writable directory"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    PLATFORM="macos-universal"
    ;;
  Linux)
    case "$ARCH" in
      x86_64|amd64) PLATFORM="linux-x86_64" ;;
      aarch64|arm64) PLATFORM="linux-aarch64" ;;
      *) fail "unsupported Linux architecture: $ARCH (build from source: https://github.com/$REPO#from-source)" ;;
    esac
    ;;
  *)
    fail "unsupported operating system: $OS (build from source: https://github.com/$REPO#from-source)"
    ;;
esac

need tar
need install
need mktemp

if command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECKSUM_CMD="shasum -a 256"
else
  fail "sha256sum or shasum is required"
fi

if [ -n "${HN_VERSION:-}" ]; then
  VERSION="${HN_VERSION#v}"
  TAG="v$VERSION"
  BASE_URL="https://github.com/$REPO/releases/download/$TAG"
  ASSET="hn-$TAG-$PLATFORM.tar.gz"
else
  BASE_URL="https://github.com/$REPO/releases/latest/download"
  ASSET="hn-$PLATFORM.tar.gz"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hn-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

say "hn installer"
say "  platform  $PLATFORM"
say "  asset     $ASSET"
say "  installing to $INSTALL_DIR"

download "$BASE_URL/$ASSET" "$TMP_DIR/$ASSET" \
  || fail "could not download $ASSET"
download "$BASE_URL/checksums.txt" "$TMP_DIR/checksums.txt" \
  || fail "could not download checksums.txt"

HASH="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TMP_DIR/checksums.txt")"
[ -n "$HASH" ] || fail "no checksum found for $ASSET"

(
  cd "$TMP_DIR"
  printf '%s  %s\n' "$HASH" "$ASSET" | $CHECKSUM_CMD -c - >/dev/null
) || fail "checksum verification failed"

tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR"
[ -f "$TMP_DIR/hn" ] || fail "the release archive did not contain hn"

install -d "$INSTALL_DIR" 2>/dev/null \
  || fail "cannot create $INSTALL_DIR; set HN_INSTALL_DIR to a writable directory"
install -m 0755 "$TMP_DIR/hn" "$INSTALL_DIR/hn" 2>/dev/null \
  || fail "cannot write to $INSTALL_DIR; set HN_INSTALL_DIR to a writable directory"

say "  installed $("$INSTALL_DIR/hn" --version 2>/dev/null || true)"
say ""
say "Run \`hn\` to open Hacker News, or \`hn capabilities\` for the JSON interface."

if [ "$OS" = "Linux" ] &&
  [ ! -e /etc/ssl/certs/ca-certificates.crt ] &&
  [ ! -d /etc/ssl/certs ]; then
  say ""
  say "Note: install ca-certificates for HTTPS (for example: sudo apt install ca-certificates)."
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    say ""
    say "Add $INSTALL_DIR to your PATH:"
    say "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac
