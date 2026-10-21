#!/bin/bash
# WHAT: The aii command onto PATH: build it from this checkout, put it at ~/.rao/bin/aii (or
#       $AII_HOME/bin) with the checkout it came from beside it (aii.json, which is where
#       `aii install` builds from), link it into ~/.local/bin when that folder exists, and say
#       how to reach it when neither folder is on PATH.
# PIN:  Builds the command only, not the servers: `aii install` does that. Copied beside its
#       destination and renamed into place, so a running aii keeps its file. A ~/.local/bin/aii
#       that isn't this link is left alone.
#
#   ./Scripts/install-cli.sh            # release
#   ./Scripts/install-cli.sh debug
#
set -euo pipefail

AII_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 64 ;; esac
HOME_DIR="${AII_HOME:-$HOME/.rao}"
BIN="$HOME_DIR/bin"

echo "▸ swift build -c $CONFIG --product aii" >&2
swift build --package-path "$AII_ROOT" -c "$CONFIG" --product aii >&2
BUILT="$(swift build --package-path "$AII_ROOT" -c "$CONFIG" --show-bin-path)/aii"
[ -x "$BUILT" ] || { echo "error: no aii at $BUILT after the build" >&2; exit 70; }

mkdir -p "$HOME_DIR" && chmod 700 "$HOME_DIR"
mkdir -p "$BIN" && chmod 755 "$BIN"

place() {   # source destination mode
    local tmp
    tmp="$(dirname "$2")/.$(basename "$2").$$.tmp"
    cp "$1" "$tmp" && chmod "$3" "$tmp"
    xattr -d com.apple.quarantine "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$2"
}
place "$BUILT" "$BIN/aii" 755

COMMIT="$(git -C "$AII_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
[ -z "$(git -C "$AII_ROOT" status --porcelain 2>/dev/null)" ] || COMMIT="$COMMIT-dirty"
cat > "$BIN/.aii.json.$$.tmp" <<JSON
{
  "checkout" : "$AII_ROOT",
  "commit" : "$COMMIT",
  "configuration" : "$CONFIG",
  "installedAt" : "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
chmod 644 "$BIN/.aii.json.$$.tmp" && mv -f "$BIN/.aii.json.$$.tmp" "$BIN/aii.json"

LINK="$HOME/.local/bin/aii"
if [ -d "$HOME/.local/bin" ]; then
    if [ -L "$LINK" ] || [ ! -e "$LINK" ]; then
        ln -sfn "$BIN/aii" "$LINK"
    else
        echo "warning: $LINK exists and isn't aii's link; left alone" >&2
    fi
fi

echo "installed aii ($COMMIT) at $BIN/aii"
case ":$PATH:" in
    *":$BIN:"*) ;;
    *":$HOME/.local/bin:"*) [ -L "$LINK" ] || echo "add to your shell profile: export PATH=\"$BIN:\$PATH\"" ;;
    *) echo "add to your shell profile: export PATH=\"$BIN:\$PATH\"" ;;
esac
