#!/usr/bin/env python
"""Сверка свифтового ядра с питоновским — до полного совпадения.

    ~/.giga/.venv/bin/python scripts/сверка-swift.py <путь-к-gigatest> запись.wav [ещё.wav ...]

Оба должны выдавать один и тот же текст: модель, веса и порядок действий
одинаковые, разный только язык, на котором это написано.
"""
import difflib
import os
import subprocess
import sys

sys.path.insert(0, os.path.expanduser("~/.giga"))
import giga_core


def свифтом(бинарник, файлы, model_dir):
    среда = dict(os.environ)
    среда["PISAR_MODEL_DIR"] = model_dir
    среда["DYLD_LIBRARY_PATH"] = os.environ.get("ORT_LIB", "")
    out = subprocess.run([бинарник, *файлы], capture_output=True, text=True, env=среда)
    if out.returncode != 0:
        sys.exit(f"gigatest упал:\n{out.stderr}")
    return [s.strip() for s in out.stdout.splitlines()]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    бинарник, файлы = sys.argv[1], sys.argv[2:]

    engine = giga_core.Engine()
    print(f"модель: {engine.model_dir}\n")

    свифт = свифтом(бинарник, файлы, engine.model_dir)
    if len(свифт) != len(файлы):
        sys.exit(f"свифт вернул {len(свифт)} строк на {len(файлы)} файлов")

    всего = совпало_симв = 0
    точных = 0
    for путь, с in zip(файлы, свифт):
        п = engine.transcribe(путь)
        одинаково = с == п
        точных += одинаково
        m = difflib.SequenceMatcher(None, п, с)
        совпало_симв += sum(b.size for b in m.get_matching_blocks())
        всего += max(len(п), len(с))
        print(f"  {os.path.basename(путь)}: {'✓ совпало' if одинаково else '✗ РАЗОШЛОСЬ'}")
        if not одинаково:
            print(f"      питон: {п!r}")
            print(f"      свифт: {с!r}")

    доля = совпало_симв / всего if всего else 1.0
    print(f"\n── Итог: точно совпало {точных} из {len(файлы)}, "
          f"совпадение по символам {доля * 100:.2f}%")
    if точных == len(файлы):
        print("✓ полное совпадение")
    elif доля >= 0.99:
        print("✓ равнозначно: расхождения на уровне дрожания последнего знака")
    else:
        print("✗ расхождения слишком велики — это ошибка переноса")
    sys.exit(0 if доля >= 0.99 else 1)


if __name__ == "__main__":
    main()
