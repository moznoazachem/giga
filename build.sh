#!/bin/zsh
# Сборка Гига.app: swiftc → бандл → ad-hoc подпись (для себя, без аккаунта Apple)
set -e
cd "$(dirname "$0")"

APP="build/Гига.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

# универсальный бинарник: Apple Silicon + Intel в одном файле
swiftc -O -target arm64-apple-macos13 -o build/Giga-arm64 main.swift
swiftc -O -target x86_64-apple-macos13 -o build/Giga-x86_64 main.swift
lipo -create build/Giga-arm64 build/Giga-x86_64 -output "$APP/Contents/MacOS/Giga"
rm build/Giga-arm64 build/Giga-x86_64
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp icon/Giga.icns "$APP/Contents/Resources/Giga.icns"

# Подпись стабильным сертификатом: разрешения (микрофон, мониторинг ввода)
# переживают пересборки. Приоритет: Apple Development → Giga Dev → ad-hoc.
if security find-identity -p codesigning -v | grep -q "Apple Development"; then
    SIGN_ID="Apple Development"
elif security find-identity -p codesigning -v | grep -q "Giga Dev"; then
    SIGN_ID="Giga Dev"
else
    SIGN_ID="-"
fi
echo "подпись: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$APP"

echo "✓ Собрано: $PWD/$APP"
