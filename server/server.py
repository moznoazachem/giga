#!/usr/bin/env python
"""Сервер распознавания для маковского приложения «Giga Pisar».

Тонкая обёртка: вся работа в pisar.py рядом. Отдельный файл нужен потому,
что приложение ищет именно server.py — так было и раньше.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pisar import serve

if __name__ == "__main__":
    serve(model_dir="")
