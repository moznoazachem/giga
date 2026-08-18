#!/bin/zsh
# Сборка Гига.app: swiftc → бандл → ad-hoc подпись (для себя, без аккаунта Apple)
set -e
cd "$(dirname "$0")"

APP="build/Гига.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/Giga" main.swift
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
