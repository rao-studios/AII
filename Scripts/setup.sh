#!/bin/bash
# WHAT: Readies a fresh checkout and puts the aii command on PATH: checks this Mac's
#       toolchain, resolves every package from GitHub (Frigate, the vendored MLX stack,
#       included), builds aii and installs it (Scripts/install-cli.sh), then says how to
#       reach it and what comes next: `aii setup`.
# IN:   [debug|release] (default release) for the aii build; --add-to-path appends the PATH
#       line to your shell profile when neither ~/.rao/bin nor ~/.local/bin is on it.
# OUT:  .build/checkouts/Frigate; ~/.rao/bin/aii (or $AII_HOME/bin) with aii.json beside it,
#       linked into ~/.local/bin when that folder exists; the next steps.
# PIN:  Apple silicon, macOS 15 and Swift 6.2 are floors: MLX runs on the GPU, Package.swift
#       sets .macOS(.v15), and traits need 6.2. SwiftPM has no Metal step, so the Metal
#       toolchain is checked here; Scripts/build-servers.sh compiles Frigate's shaders with
#       it. Building the servers takes a while the first time, so this stops before it:
#       `aii setup` builds them, asks for your key, starts the index and pulls the models.
#       Building aii already resolves the whole graph (traits are package-wide), so the
#       resolve costs the Rao-apps path nothing extra.
#
#   ./Scripts/setup.sh
#   ./Scripts/setup.sh debug --add-to-path
#
set -euo pipefail
AII_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$AII_ROOT"

CONFIG=release
ADD_TO_PATH=false
for argument in "$@"; do
    case "$argument" in
        debug|release) CONFIG="$argument" ;;
        --add-to-path) ADD_TO_PATH=true ;;
        *) echo "usage: $0 [debug|release] [--add-to-path]" >&2; exit 64 ;;
    esac
done

fail() {
    echo "✗ $1" >&2
    [ $# -gt 1 ] && echo "  $2" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail "AII's servers run on macOS."
[ "$(uname -m)" = arm64 ] || fail "AII's servers need Apple silicon: MLX runs on its GPU."
macos="$(sw_vers -productVersion)"
[ "${macos%%.*}" -ge 15 ] || fail "macOS $macos: AII needs macOS 15 or later."
echo "✓ macOS $macos on Apple silicon"

command -v swift > /dev/null || fail "No swift on PATH." "Install Xcode 26 or later, then: sudo xcode-select -s /Applications/Xcode.app"
swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
major="${swift_version%%.*}"
minor="${swift_version#*.}"
{ [ "${major:-0}" -gt 6 ] || { [ "${major:-0}" -eq 6 ] && [ "${minor:-0}" -ge 2 ]; }; } \
    || fail "Swift ${swift_version:-unknown}: AII needs Swift 6.2 or later (Xcode 26)."
echo "✓ Swift $swift_version"

if ! xcrun -sdk macosx -f metal > /dev/null 2>&1; then
    echo "▸ Metal toolchain: xcodebuild -downloadComponent MetalToolchain"
    xcodebuild -downloadComponent MetalToolchain
    xcrun -sdk macosx -f metal > /dev/null 2>&1 \
        || fail "Still no Metal toolchain." "Install it from Xcode → Settings → Components."
fi
echo "✓ Metal toolchain"

echo "▸ swift package resolve"
swift package resolve
for dep in Frigate; do
    [ -d ".build/checkouts/$dep" ] || [ -d "Packages/$dep" ] || fail "$dep did not resolve."
done
echo "✓ Frigate resolved"

echo "▸ Scripts/install-cli.sh $CONFIG"
installed="$(Scripts/install-cli.sh "$CONFIG")" || fail "Scripts/install-cli.sh $CONFIG failed (its output is above)."
printf '%s\n' "$installed" | grep -v '^add to your shell profile' || true   # setup.sh says it once, below

# aii on PATH: ~/.rao/bin itself, or the ~/.local/bin link install-cli.sh made.
BIN="${AII_HOME:-$HOME/.rao}/bin"
LINK="$HOME/.local/bin/aii"
[ -x "$BIN/aii" ] || fail "no aii at $BIN/aii after the install."
on_path=false
case ":$PATH:" in *":$BIN:"*) on_path=true ;; esac
if ! $on_path && [ -L "$LINK" ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) on_path=true ;; esac
fi
if [ -n "${AII_HOME:-}" ]; then LINE="export PATH=\"$BIN:\$PATH\""; else LINE='export PATH="$HOME/.rao/bin:$PATH"'; fi
case "$(basename "${SHELL:-zsh}")" in
    zsh) PROFILE="$HOME/.zshrc" ;;
    bash) PROFILE="$HOME/.bash_profile" ;;
    *) PROFILE="$HOME/.profile" ;;
esac

reach=aii
if $on_path; then
    echo "✓ aii on PATH ($BIN/aii)"
elif $ADD_TO_PATH; then
    if ! grep -qF "$LINE" "$PROFILE" 2>/dev/null; then
        printf '\n# AII: the aii command\n%s\n' "$LINE" >> "$PROFILE"
    fi
    echo "✓ aii added to PATH in ${PROFILE/#$HOME/~} · open a new terminal, or: $LINE"
    reach="$BIN/aii"
else
    echo "▸ aii is at $BIN/aii, not on PATH. Add this line to ${PROFILE/#$HOME/~} (or run: Scripts/setup.sh --add-to-path):"
    echo "    $LINE"
    reach="$BIN/aii"
fi

cat <<EOF

Next:
  cp .env.example .env        # optional: your API key, Mistral or Tinker
  $reach setup                 # your key into ~/.rao, the servers built and installed (or a Rao app's kept), the index up, the two models
  $reach                       # the studio
EOF
