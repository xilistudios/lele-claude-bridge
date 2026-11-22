#!/bin/sh
# Lele Claude bridge installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/xilistudios/lele-claude-bridge/main/install.sh | sh
#   curl -fsSL ... | sh -s -- --dir /opt/lele/claude-bridge --ref v0.1.0
#
# Installs the bridge modules, the pinned package metadata and the Claude Agent
# SDK into ${LELE_CONFIG_DIR:-$HOME/.lele}/claude-bridge, the directory lele
# looks for at bridge start.
set -eu

REPO="xilistudios/lele-claude-bridge"
REF="main"
SKIP_SDK=0
DIR_ARG=""
NODE_MIN_MAJOR=18
NODE_MIN_MINOR=14

usage() {
  cat <<EOF
Lele Claude bridge installer

Usage:
  sh install.sh [options]

Options:
  --dir DIR     Install directory (default: \${LELE_CONFIG_DIR:-\$HOME/.lele}/claude-bridge)
  --ref REF     Branch, tag or commit to install (default: main)
  --skip-sdk    Copy the bridge files only: no npm, no handshake smoke test
  --help        Show this message

Examples:
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --ref v0.1.0
EOF
}

# ── Helpers ──────────────────────────────────────────────────────────

log()   { printf '  %s\n' "$@"; }
info()  { printf '\033[1;34m==> %s\033[0m\n' "$@"; }
ok()    { printf '\033[1;32m==> %s\033[0m\n' "$@"; }
err()   { printf '\033[1;31mError: %s\033[0m\n' "$@" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || err "'$1' is required but not found."
}

http_get() {
  url="$1"; dst="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dst" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$url"
  else
    err "curl or wget is required."
  fi
}

# ── Arguments ────────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || err "--dir requires a directory"
      DIR_ARG="$2"
      shift 2
      ;;
    --ref)
      [ "$#" -ge 2 ] || err "--ref requires a git ref"
      REF="$2"
      shift 2
      ;;
    --skip-sdk)
      SKIP_SDK=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      err "unknown option: $1 (try --help)"
      ;;
  esac
done

# ── Resolve the install directory ────────────────────────────────────

normalize_dir() {
  dir="$1"
  tilde="~"
  case "$dir" in
    "$tilde")   dir="$HOME" ;;
    "$tilde"/*) dir="$HOME/${dir#"$tilde"}";;
  esac
  while [ "${#dir}" -gt 1 ] && [ "${dir%/}" != "$dir" ]; do
    dir="${dir%/}"
  done
  printf '%s\n' "$dir"
}

STATE_DIR="${LELE_CONFIG_DIR:-$HOME/.lele}"
DEFAULT_DIR="$(normalize_dir "$STATE_DIR/claude-bridge")"
case "$DEFAULT_DIR" in
  /*) ;;
  *) DEFAULT_DIR="$(pwd)/$DEFAULT_DIR" ;;
esac

if [ -n "$DIR_ARG" ]; then
  DIR="$(normalize_dir "$DIR_ARG")"
else
  DIR="$(normalize_dir "${LELE_CONFIG_DIR:-$HOME/.lele}/claude-bridge")"
fi

[ -n "$DIR" ] || err "the install directory is empty"
[ "$DIR" != "/" ] || err "refusing to install into /"

case "$DIR" in
  /*) ;;
  *)
    log "warning: relative install directory resolved against the current directory;"
    log "         lele resolves a relative LELE_CONFIG_DIR against its own working"
    log "         directory, so prefer an absolute path here."
    DIR="$(pwd)/$DIR"
    ;;
esac

if [ -e "$DIR" ] && [ ! -d "$DIR" ]; then
  err "$DIR exists and is not a directory"
fi

PARENT="$(dirname "$DIR")"
mkdir -p "$PARENT"

# ── Preflight ────────────────────────────────────────────────────────

need node
NODE_VERSION="$(node --version)"
NODE_NUMERIC="${NODE_VERSION#v}"
NODE_MAJOR="${NODE_NUMERIC%%.*}"
NODE_REST="${NODE_NUMERIC#*.}"
NODE_MINOR="${NODE_REST%%.*}"
case "$NODE_MAJOR$NODE_MINOR" in
  ''|*[!0-9]*) err "could not parse the node version (found $NODE_VERSION)" ;;
esac
if [ "$NODE_MAJOR" -lt "$NODE_MIN_MAJOR" ] ||
   { [ "$NODE_MAJOR" -eq "$NODE_MIN_MAJOR" ] && [ "$NODE_MINOR" -lt "$NODE_MIN_MINOR" ]; }; then
  err "node >= $NODE_MIN_MAJOR.$NODE_MIN_MINOR is required (found $NODE_VERSION); that is the Claude Agent SDK engines floor"
fi

if [ "$SKIP_SDK" -eq 0 ]; then
  command -v npm >/dev/null 2>&1 ||
    err "npm is required to install the Claude Agent SDK; re-run with --skip-sdk and set CLAUDE_AGENT_SDK_PATH to an existing node_modules instead"
fi

need tar

# ── Staging ──────────────────────────────────────────────────────────

STAGING="$(mktemp -d "$PARENT/claude-bridge.staging.XXXXXX")"
OLD=""
SWAPPED=0

cleanup() {
  rm -rf "$STAGING"
  if [ "$SWAPPED" -eq 1 ] && [ -n "$OLD" ]; then
    rm -rf "$OLD"
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fetch_tarball() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    return 1
  fi
  http_get "https://codeload.github.com/$REPO/tar.gz/$REF" "$STAGING/src.tar.gz"
}

info "Installing $REPO@$REF"

SRC=""
if fetch_tarball; then
  tar -xzf "$STAGING/src.tar.gz" -C "$STAGING" ||
    err "could not extract the downloaded bridge tarball"
  FOUND=""
  COUNT=0
  for candidate in "$STAGING"/lele-claude-bridge-*/; do
    [ -d "$candidate" ] || continue
    FOUND="$candidate"
    COUNT=$((COUNT + 1))
  done
  [ "$COUNT" -eq 1 ] ||
    err "bridge repo layout changed: expected exactly one top-level directory in the tarball, found $COUNT"
  SRC="${FOUND%/}"
elif command -v git >/dev/null 2>&1; then
  info "Download failed, falling back to git clone"
  git clone --quiet "https://github.com/$REPO.git" "$STAGING/src" ||
    err "could not clone https://github.com/$REPO.git"
  git -C "$STAGING/src" checkout --quiet "$REF" ||
    err "could not check out $REF in the cloned bridge repo"
  SRC="$STAGING/src"
else
  err "could not download the bridge (no network?); install manually: git clone https://github.com/$REPO.git && cd lele-claude-bridge && npm ci --omit=dev --no-audit --no-fund"
fi

# ── Copy the runtime files ───────────────────────────────────────────

mkdir -p "$STAGING/install"
for file in bridge.mjs bridge_lib.mjs bridge_test.mjs package.json; do
  [ -f "$SRC/$file" ] || err "bridge repo layout changed: missing $file"
  cp "$SRC/$file" "$STAGING/install/$file"
  chmod 0644 "$STAGING/install/$file"
done
if [ -f "$SRC/package-lock.json" ]; then
  cp "$SRC/package-lock.json" "$STAGING/install/package-lock.json"
  chmod 0644 "$STAGING/install/package-lock.json"
else
  log "warning: package-lock.json is missing from $REPO@$REF; falling back to npm install"
fi

# ── Install the SDK ──────────────────────────────────────────────────

SDK_MARKER="skipped"
if [ "$SKIP_SDK" -eq 0 ]; then
  info "Installing the Claude Agent SDK"
  if [ -f "$STAGING/install/package-lock.json" ]; then
    (cd "$STAGING/install" && npm ci --omit=dev --no-audit --no-fund) ||
      err "npm ci failed in the staging directory; nothing was changed in $DIR"
  else
    (cd "$STAGING/install" && npm install --omit=dev --no-audit --no-fund) ||
      err "npm install failed in the staging directory; nothing was changed in $DIR"
  fi
  [ -f "$STAGING/install/node_modules/@anthropic-ai/claude-agent-sdk/package.json" ] ||
    err "npm finished but node_modules/@anthropic-ai/claude-agent-sdk is missing"
  if ! SDK_MARKER="$(node -e '
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const pin = (pkg.dependencies || {})["@anthropic-ai/claude-agent-sdk"];
if (!pin) process.exit(1);
process.stdout.write(pin);
' "$STAGING/install/package.json")"; then
    err "could not read the pinned SDK version from package.json"
  fi
fi

INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"repo":"%s","ref":"%s","installed_at":"%s","sdk":"%s"}\n' \
  "$REPO" "$REF" "$INSTALLED_AT" "$SDK_MARKER" > "$STAGING/install/.install-info.json"
chmod 0644 "$STAGING/install/.install-info.json"

# ── Swap into place ──────────────────────────────────────────────────

if [ -d "$DIR" ]; then
  OLD="${DIR}.old.$$"
  mv "$DIR" "$OLD" || err "could not move the existing install aside"
fi
if mv "$STAGING/install" "$DIR"; then
  SWAPPED=1
  if [ -n "$OLD" ]; then
    rm -rf "$OLD"
  fi
else
  if [ -n "$OLD" ]; then
    mv "$OLD" "$DIR" || err "could not move the new bridge into $DIR and the rollback failed; the previous install is at $OLD"
  fi
  err "could not move the new bridge into $DIR"
fi

# ── Handshake smoke test ─────────────────────────────────────────────

if [ "$SKIP_SDK" -eq 0 ]; then
  READY="$(printf '%s\n' '{"type":"init","sdk_search_paths":[],"claude_path":""}' |
    node "$DIR/bridge.mjs" 2>/dev/null | head -1)"
  case "$READY" in
    *'"type":"ready"'*) ;;
    *) err "the installed bridge did not report ready: $READY" ;;
  esac
fi

# ── Done ─────────────────────────────────────────────────────────────

ok "Claude bridge installed in $DIR"
log "ref: $REPO@$REF"
log "Claude Agent SDK: $SDK_MARKER"
if [ -n "${LELE_CONFIG_DIR:-}" ] && [ -z "$DIR_ARG" ]; then
  log "using LELE_CONFIG_DIR=$LELE_CONFIG_DIR"
fi
log ""
log "Next steps:"
log "  1. Point lele at the claude-code provider:"
log "       agents:"
log "         defaults:"
log "           provider: claude-code"
log "           model: claude-sonnet-4-5"
log "  2. Run 'claude' once and log in with your Claude subscription (no API key)."
if [ "$DIR" != "$DEFAULT_DIR" ]; then
  log "  3. lele will not find this directory by default; export it:"
  log "       export LELE_CLAUDE_BRIDGE_PATH=$DIR"
fi
log ""
log "Update later by re-running the same installer."