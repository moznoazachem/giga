#!/bin/bash
# Установка серверной части Гиги (распознавание речи GigaAM) в ~/.giga
set -e
cd "$(dirname "$0")"

echo "== Гига: установка серверной части =="

# ffmpeg нужен для конвертации аудио
if ! command -v ffmpeg >/dev/null; then
    echo "Нужен ffmpeg. Поставь и запусти скрипт снова:"
    echo "  brew install ffmpeg"
    exit 1
fi

# Python 3.10–3.12 (более новые пока не дружат с PyTorch)
PY=""
for v in python3.12 python3.11 python3.10; do
    command -v $v >/dev/null && PY=$(command -v $v) && break
done
if [ -z "$PY" ]; then
    echo "Нужен Python 3.10–3.12. Поставь и запусти скрипт снова:"
    echo "  brew install python@3.12"
    exit 1
fi
echo "Python: $PY"

mkdir -p ~/.giga
cp server/server.py server/transcribe.py ~/.giga/

if [ ! -d ~/.giga/.venv ]; then
    "$PY" -m venv ~/.giga/.venv
fi
echo "Ставлю зависимости (PyTorch тяжёлый, может занять несколько минут)..."
~/.giga/.venv/bin/pip install -q --upgrade pip
~/.giga/.venv/bin/pip install -q "git+https://github.com/salute-developers/GigaAM" fastapi uvicorn python-multipart

echo ""
echo "✓ Готово. Теперь:"
echo "  1. Скопируй Гига.app в Программы и открой (правый клик → Open при первом запуске)"
echo "  2. Разреши три доступа, которые она попросит (клавиатура, микрофон, вставка текста)"
echo "  3. При первой диктовке модель (~450 МБ) скачается автоматически — подожди"
echo "  4. Зажми правый ⌘ и говори"
