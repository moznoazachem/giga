#!/usr/bin/env python
"""giga — транскрибация аудио через GigaAM v3 (Сбер).

Использование:
    giga file.m4a [file2.wav ...]     — печатает транскрипт в stdout
    giga --rec [секунды]              — записать с микрофона и распознать (по умолчанию 15с)
    giga -m <модель> ...              — выбрать модель

Модели:
    e2e_rnnt (дефолт) — русский, с пунктуацией и заглавными
    rnnt              — русский, сырой текст, чуть быстрее
    mul               — multilingual_ctc: 70+ языков, английский, код-свитчинг
    mul_large         — multilingual_large_ctc: то же, крупнее и точнее

Любой формат аудио (m4a/mp3/ogg/wav/...) — конвертируется через ffmpeg.
Файлы длиннее 25с режутся на куски по паузам (silencedetect) и склеиваются.
"""
import os
import subprocess
import sys
import tempfile

os.environ.setdefault("PYTHONWARNINGS", "ignore")
import warnings

warnings.filterwarnings("ignore")

MAX_CHUNK = 24.0  # лимит gigaam.transcribe — 25с
MIC_DEVICE = ":3"  # MacBook Pro Microphone


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout.strip())


def find_silences(path):
    """Середины пауз >=0.3с — кандидаты в точки разреза."""
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", path, "-af",
         "silencedetect=noise=-35dB:d=0.3", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    points, start = [], None
    for line in out.stderr.splitlines():
        if "silence_start:" in line:
            start = float(line.split("silence_start:")[1].strip())
        elif "silence_end:" in line and start is not None:
            end = float(line.split("silence_end:")[1].split("|")[0].strip())
            points.append((start + end) / 2)
            start = None
    return points


def chunk_bounds(total, silences):
    """Куски <=MAX_CHUNK, резка по ближайшей паузе перед лимитом."""
    bounds, pos = [], 0.0
    while total - pos > MAX_CHUNK:
        candidates = [s for s in silences if pos + 3 < s <= pos + MAX_CHUNK]
        cut = candidates[-1] if candidates else pos + MAX_CHUNK
        bounds.append((pos, cut))
        pos = cut
    bounds.append((pos, total))
    return bounds


def _text(result):
    return getattr(result, "text", result) or ""


def transcribe_file(model, path, tmpdir):
    wav = os.path.join(tmpdir, "in.wav")
    ffmpeg("-i", path, "-ac", "1", "-ar", "16000", wav)
    total = duration(wav)
    if total <= MAX_CHUNK + 1:
        return _text(model.transcribe(wav))
    pieces = []
    for i, (a, b) in enumerate(chunk_bounds(total, find_silences(wav))):
        part = os.path.join(tmpdir, f"part{i}.wav")
        ffmpeg("-i", wav, "-ss", str(a), "-to", str(b), part)
        pieces.append(_text(model.transcribe(part)))
    return " ".join(p for p in pieces if p)


LAST_REC = os.path.expanduser("~/projects/gigaam-cli/last_rec.wav")


def record(seconds):
    print(f"🎙  ЗАПИСЬ ПОШЛА ({seconds}с) — говори!", file=sys.stderr)
    ffmpeg("-f", "avfoundation", "-i", MIC_DEVICE, "-t", str(seconds),
           "-ac", "1", "-ar", "16000", LAST_REC)
    print("⏹  Записано (сохранил в last_rec.wav), распознаю...", file=sys.stderr)
    return LAST_REC


MODEL_ALIASES = {
    "mul": "multilingual_ctc",
    "mul_large": "multilingual_large_ctc",
}


def main():
    args = sys.argv[1:]
    model_name = "e2e_rnnt"
    if args and args[0] in ("-m", "--model"):
        model_name = MODEL_ALIASES.get(args[1], args[1])
        args = args[2:]
    if not args:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    recorded = None
    if args[0] == "--rec":
        seconds = int(args[1]) if len(args) > 1 else 15
        recorded = record(seconds)

    import gigaam

    print(f"[GigaAM: загрузка модели {model_name}...]", file=sys.stderr)
    model = gigaam.load_model(model_name)

    with tempfile.TemporaryDirectory() as tmpdir:
        if recorded:
            print(transcribe_file(model, recorded, tmpdir))
        else:
            for f in args:
                if len(args) > 1:
                    print(f"── {os.path.basename(f)}", file=sys.stderr)
                print(transcribe_file(model, f, tmpdir))


if __name__ == "__main__":
    main()
