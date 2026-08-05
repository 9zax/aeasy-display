#!/bin/zsh
# builds everything and installs the `aeasy` command
set -e
DIR="${0:A:h}"
SHARE="$HOME/.local/share/aeasy"

echo "▸ building mac binaries..."
make -C "$DIR" build

mkdir -p "$SHARE" "$HOME/.local/bin"
cp "$DIR/mac/aeasy-server" "$DIR/mac/aeasy-config" "$DIR/mac/aeasy-tray" "$DIR/docs/logo.svg" "$SHARE/"
APK="$DIR/android/app/build/outputs/apk/debug/app-debug.apk"
[[ -f "$APK" ]] && cp "$APK" "$SHARE/"
# iOS app ships as source: `aeasy install-app` copies this to $SHARE/ios (writable —
# Xcode records the user's signing team there) and opens Xcode for a free-Apple-ID Run.
# Protocol.swift sits outside ios/ in the repo, so place a copy where the pbxproj's
# ../../mac reference can't reach and rewire is not needed: keep the tree shape.
rm -rf "$SHARE/ios-src"
mkdir -p "$SHARE/ios-src/mac"
cp -R "$DIR/ios/." "$SHARE/ios-src/ios"
cp "$DIR/mac/Protocol.swift" "$SHARE/ios-src/mac/Protocol.swift"
cp "$DIR/bin/aeasy" "$HOME/.local/bin/aeasy"
chmod +x "$HOME/.local/bin/aeasy"

if ! grep -q 'aeasy' ~/.zshrc 2>/dev/null; then
  cat >> ~/.zshrc <<'EOF'

# AEasy Display — Android USB second screen
export PATH="$HOME/.local/bin:$PATH"
alias aez='aeasy'
EOF
  echo "▸ added PATH + alias to ~/.zshrc"
fi

echo "✅ Installed — open a new terminal (or source ~/.zshrc) then run:"
echo "   aeasy start   |   aeasy --help"
