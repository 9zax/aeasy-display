#!/bin/zsh
# builds everything and installs the `aeasy` command
set -e
DIR="${0:A:h}"
SHARE="$HOME/.local/share/aeasy"

echo "▸ building mac server..."
(cd "$DIR/mac" && swiftc -O -import-objc-header virtual-display.h -o aeasy-server AEasyServer.swift)
echo "▸ building config app..."
(cd "$DIR/mac" && swiftc -O -o aeasy-config AEasyConfig.swift)
echo "▸ building menu bar app..."
(cd "$DIR/mac" && swiftc -O -o aeasy-tray AEasyTray.swift)

mkdir -p "$SHARE" "$HOME/.local/bin"
cp "$DIR/mac/aeasy-server" "$DIR/mac/aeasy-config" "$DIR/mac/aeasy-tray" "$DIR/logo.svg" "$SHARE/"
APK="$DIR/android/app/build/outputs/apk/debug/app-debug.apk"
[[ -f "$APK" ]] && cp "$APK" "$SHARE/"
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
