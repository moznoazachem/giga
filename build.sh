#!/bin/zsh
# Сборка «Giga Pisar.app»: swiftc → бандл → подпись → установка в Программы.
#   ./build.sh                собрать и поставить
#   ./build.sh --with-model   ещё и положить модель внутрь приложения
#                             (получится самодостаточный кусок на ~390 МБ)
set -e
cd "$(dirname "$0")"

WITH_MODEL=0
[ "${1:-}" = "--with-model" ] && WITH_MODEL=1

ORT_VER="1.23.2"
ORT_DIR="vendor/onnxruntime-osx-universal2-$ORT_VER"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VER/onnxruntime-osx-universal2-$ORT_VER.tgz"

# Библиотека, которая считает модель. Универсальная — Apple Silicon и Intel
# в одном файле. В репозиторий не кладём: 75 МБ, качается сама.
if [ ! -d "$ORT_DIR" ]; then
    echo "── качаю onnxruntime $ORT_VER (41 МБ)"
    mkdir -p vendor
    curl -fL --progress-bar -o vendor/ort.tgz "$ORT_URL"
    tar xzf vendor/ort.tgz -C vendor
    rm vendor/ort.tgz
fi
ORT_LIB="$ORT_DIR/lib/libonnxruntime.$ORT_VER.dylib"

APP="build/Giga Pisar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

SOURCES=(main.swift swift/Ort.swift swift/Features.swift swift/Tokenizer.swift
         swift/Recognizer.swift swift/Audio.swift swift/WavePanel.swift swift/Updates.swift
         swift/Onboarding.swift)

# универсальный бинарник: Apple Silicon + Intel в одном файле
echo "── сборка"
for ARCH in arm64 x86_64; do
    swiftc -O -target $ARCH-apple-macos13.4 \
        -import-objc-header swift/bridge.h \
        -I "$ORT_DIR/include" -L "$ORT_DIR/lib" -lonnxruntime \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -o "build/Giga-$ARCH" "${SOURCES[@]}"
done
lipo -create build/Giga-arm64 build/Giga-x86_64 -output "$APP/Contents/MacOS/Giga"
rm build/Giga-arm64 build/Giga-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp icon/Giga.icns "$APP/Contents/Resources/Giga.icns"
cp "$ORT_LIB" "$APP/Contents/Frameworks/"

if [ "$WITH_MODEL" = "1" ]; then
    SRC=""
    for D in "$HOME/.giga/model" "$HOME/projects/gigaam-cli/onnx_int8"; do
        [ -f "$D/v3_e2e_rnnt.yaml" ] && SRC="$D" && break
    done
    if [ -z "$SRC" ]; then
        echo "   модель не нашлась — сначала ./install.sh"; exit 1
    fi
    echo "── кладу модель внутрь ($SRC)"
    mkdir -p "$APP/Contents/Resources/model"
    cp "$SRC"/v3_e2e_rnnt* "$APP/Contents/Resources/model/"
    # В yaml записан путь к токенизатору с той машины, где делали экспорт.
    # Приложению он не нужен (ищет токенизатор рядом с моделью), а чужой
    # домашний каталог в раздаваемом файле — лишнее. Затираем.
    sed -i '' 's|model_path: .*|model_path: v3_e2e_rnnt_tokenizer.model|' \
        "$APP/Contents/Resources/model/v3_e2e_rnnt.yaml"
fi

# Подпись стабильным сертификатом: разрешения (микрофон, мониторинг ввода)
# переживают пересборки. Приоритет: Apple Development → Giga Dev → ad-hoc.
if security find-identity -p codesigning -v | grep -q "Apple Development"; then
    SIGN_ID="Apple Development"
elif security find-identity -p codesigning -v | grep -q "Giga Dev"; then
    SIGN_ID="Giga Dev"
else
    SIGN_ID="-"
fi
echo "── подпись: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/libonnxruntime.$ORT_VER.dylib"
codesign --force --sign "$SIGN_ID" "$APP"

# Установка в «Программы»: там приложение видно в Finder и Spotlight.
DEST="/Applications/Giga Pisar.app"
osascript -e 'quit app "Giga Pisar"' 2>/dev/null || true
sleep 1
if [ -d "$DEST" ]; then rm -rf "$DEST"; fi
cp -R "$APP" "$DEST"

# Сборка погасила работающую копию — запускаем новую, чтобы диктовка
# не пропадала молча до следующего входа в систему.
open "$DEST"

echo
echo "✓ Установлено и запущено: $DEST  ($(du -sh "$DEST" | cut -f1))"
