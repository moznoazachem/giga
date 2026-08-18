#!/usr/bin/env python
"""Локальный STT-сервер на GigaAM с OpenAI-совместимым API.

Слушает http://127.0.0.1:8737. Эндпоинт как у OpenAI:
    POST /v1/audio/transcriptions  (multipart: file=<аудио>, model=<игнорируется>)
    → {"text": "..."}

Подключение в MacWhisper: Settings → Cloud Transcription → кастомный
OpenAI-совместимый провайдер, base URL http://127.0.0.1:8737/v1, ключ любой.

Модель: e2e_rnnt (русский, пунктуация). Держится в памяти после первого запроса.
Длинные файлы режутся по паузам — логика из transcribe.py.
"""
import os
import sys
import tempfile
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import warnings

warnings.filterwarnings("ignore")

from fastapi import FastAPI, File, UploadFile
from fastapi.responses import JSONResponse

from transcribe import transcribe_file

app = FastAPI()
_model = None
_lock = threading.Lock()


def get_model():
    global _model
    with _lock:
        if _model is None:
            import gigaam

            print("[giga-server] загрузка модели e2e_rnnt...", flush=True)
            _model = gigaam.load_model("e2e_rnnt")
            print("[giga-server] модель готова", flush=True)
        return _model


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/v1/audio/transcriptions")
async def transcriptions(file: UploadFile = File(...)):
    model = get_model()
    data = await file.read()
    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "upload" + suffix)
        with open(src, "wb") as f:
            f.write(data)
        try:
            with _lock:
                text = transcribe_file(model, src, tmpdir)
        except Exception as e:
            return JSONResponse({"error": {"message": str(e)}}, status_code=500)
    return {"text": str(text)}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8737, log_level="warning")
