# Giga Pisar

*[English](#english) · [Русский](#русский)*

---

## English

Voice dictation for macOS powered by [GigaAM v3](https://github.com/salute-developers/GigaAM) —
Sber's open SOTA model for Russian speech recognition. More accurate than Whisper on Russian,
adds punctuation and capitalization on its own, and runs **fully on-device** — audio never
leaves your Mac.

**Hold a key → speak → release → punctuated text appears wherever your cursor is.**
In any application.

### What's inside

Recognition runs **inside the app itself**. No Python, no ffmpeg, no Homebrew,
no companion server.

- `main.swift` — the menu bar app: push-to-talk key capture, microphone recording, text insertion
- `swift/` — the recognition core in Swift:
  `Features.swift` (audio → features), `Ort.swift` (model inference),
  `Recognizer.swift` (RNN-T decoding), `Tokenizer.swift` (text assembly),
  `Audio.swift` (wav reading, splitting on pauses)
- `vendor/` — the onnxruntime library, downloaded by the build script (not in the repo)
- `install.sh` — puts the model files into `~/.giga/model`

The core is a Swift port of `giga_core.py` from
[Giga Pisar for Linux](https://github.com/moznoazachem/giga-pisar).
Both are run on the same recordings by `scripts/сверка-swift.py` and must
produce identical text.

Menu labels follow the system language: Russian system — Russian labels,
anything else — English.

### Performance

Measured on Apple Silicon:

| What | Time |
|---|---|
| 6-second recording | **0.08 s** |
| 30-second recording (split on pauses) | 0.47 s |
| model load at startup | 0.22 s |

The app weighs 72 MB, 71 of which is the onnxruntime library (universal,
Apple Silicon and Intel in one file). The model adds 309 MB.
About 450 MB resident in memory.

### Install

```bash
git clone <this-repo>
cd giga-app
./install.sh          # model into ~/.giga/model (204 MB download)
./build.sh            # builds and installs "Giga Pisar.app" into Applications
open "/Applications/Giga Pisar.app"
```

Building needs Xcode or Command Line Tools. Nothing else.

Or grab the ready-made app from [Releases](../../releases) — it ships with the
model inside: download, drag to Applications, done.

You can also build a self-contained app with the model embedded:

```bash
./build.sh --with-model     # ~390 MB, no install.sh needed
```

The app is signed with a developer certificate but **not notarized**, so macOS
blocks the first launch. Fix it once: **System Settings → Privacy & Security**,
scroll down to the blocked-app message → **Open Anyway**. (The old
"right-click → Open" trick no longer works on macOS 15+ — Apple removed it.)

### First run

A welcome window walks you through the **two** permissions, with live
checkmarks (also available later via "Permissions…" in the menu):

1. **Microphone** — to record your voice
2. **Accessibility** — to insert text (pressing ⌘V for you)

Enable the "Giga Pisar" toggle in the settings pane that opens — **via the
system prompt, not the "+" button**.

The push-to-talk key needs **no permission at all**: macOS guards the
*content* of what you type, and modifier keys (⌘/⌥/⌃/Fn) aren't content.
The app tracks only those — it cannot see your keystrokes even in principle.
(Versions up to 2.1 asked for Input Monitoring for this; if you granted it
back then, you can safely remove that entry in System Settings.)

If a toggle is on but nothing works, the permissions database has a stale
entry. Reset it:

```bash
tccutil reset Accessibility ru.panda.giga
```

(same for `Microphone`), then let the app request access again.

### Usage

- **Hold right ⌘** (configurable in the menu) → speak → release → text is inserted
- Menu bar icon: waveform — ready; red dancing — recording; dots — transcribing
- Click the icon for: mouse-driven recording, key selection, launch at login
- **Wave near cursor** — a small floating pill with your live voice level appears
  next to the text caret while you dictate (falls back to the mouse pointer when
  the app won't reveal its caret). Toggle it in the menu
- Long dictations are split on pauses between phrases and stitched back together

### Updates

The menu shows the current version and a "Check for updates…" item. The app also
asks GitHub every few hours whether a newer release exists — only the version
number travels over the network, nothing else. Updates are never installed
automatically: you get a notice and a link to the releases page.

### Limitations

- Russian only. English speech comes out in Cyrillic ("зэ квик браун фокс") —
  use Whisper for English
- Internet is needed once, to download the model; offline after that

### Credits

- [GigaAM](https://github.com/salute-developers/GigaAM) — the recognition model, SberDevices (MIT)

### License

MIT

---

## Русский

Диктовка голосом для macOS на модели [GigaAM v3](https://github.com/salute-developers/GigaAM)
от Сбера — открытой SOTA-модели распознавания русской речи. Точнее Whisper на русском,
сама расставляет пунктуацию и заглавные, работает **полностью локально** — звук
не покидает твой компьютер.

**Зажал клавишу → говоришь → отпустил → текст с пунктуацией появился там, где курсор.**
В любом приложении.

### Что внутри

Распознавание работает **внутри самого приложения**. Ни питона, ни ffmpeg,
ни Homebrew, ни какого-либо сервера рядом.

- `main.swift` — приложение в строке меню: перехват клавиши-рации,
  запись с микрофона, вставка текста
- `swift/` — ядро распознавания на Swift:
  `Features.swift` (звук → признаки), `Ort.swift` (запуск модели),
  `Recognizer.swift` (декодирование RNN-T), `Tokenizer.swift` (сборка текста),
  `Audio.swift` (чтение wav, нарезка по паузам)
- `vendor/` — библиотека onnxruntime, качается сборкой сама (в репозиторий не входит)
- `install.sh` — кладёт файлы модели в `~/.giga/model`

Ядро — перенос на Swift питоновского `giga_core.py` из
[Гига Писаря для Linux](https://github.com/moznoazachem/giga-pisar).
Оба гоняются на одних записях скриптом `scripts/сверка-swift.py` и должны
выдавать один и тот же текст.

Надписи в меню подстраиваются под язык системы: русская система — русские,
любая другая — английские.

### Сколько работает

Замеры на Apple Silicon:

| Что | Время |
|---|---|
| запись 6 секунд | **0,08 с** |
| запись 30 секунд (режется по паузам) | 0,47 с |
| загрузка модели при запуске | 0,22 с |

Приложение весит 72 МБ, из них 71 — библиотека onnxruntime (универсальная,
Apple Silicon и Intel в одном файле). Модель — ещё 309 МБ.
В памяти держит около 450 МБ.

### Установка

```bash
git clone <этот-репозиторий>
cd giga-app
./install.sh          # модель в ~/.giga/model (204 МБ качается)
./build.sh            # собирает и ставит «Giga Pisar.app» в Программы
open "/Applications/Giga Pisar.app"
```

Для сборки нужен Xcode или Command Line Tools. Больше ничего ставить не надо.

Либо возьми готовое приложение из [Releases](../../releases) — там сборка
с моделью внутри: скачал, перетащил в Программы, больше ничего не нужно.

Можно собрать самодостаточное приложение, с моделью внутри:

```bash
./build.sh --with-model     # получится около 390 МБ, install.sh не нужен
```

Приложение подписано сертификатом разработчика, но **не нотаризовано**, поэтому
при первом запуске macOS его заблокирует. Лечится один раз:
**System Settings → Privacy & Security**, пролистать вниз до сообщения о
заблокированном приложении → **Open Anyway**. (Прежний способ «правый клик → Open»
на macOS 15 и новее больше не работает — Apple его убрала.)

### Первый запуск

Окно первого запуска проведёт по **двум** разрешениям, с живыми галочками
(потом открывается через «Доступы…» в меню):

1. **Микрофон** — записывать голос
2. **Универсальный доступ** — вставлять текст (нажимать ⌘V за тебя)

Включай тумблер «Giga Pisar» в открывшихся настройках — **через системный запрос,
а не через «+»**.

Клавиша-рация **не требует разрешений вовсе**: macOS охраняет *содержимое*
набора, а модификаторы (⌘/⌥/⌃/Fn) содержимым не считаются. Приложение следит
только за ними — твои нажатия букв оно не видит даже в принципе.
(Версии до 2.1 просили для этого «Мониторинг ввода»; если выдавал его тогда —
можешь спокойно убрать эту строчку в настройках.)

Если тумблер включён, а не работает — в базе разрешений битая запись. Лечится так:

```bash
tccutil reset Accessibility ru.panda.giga
```

(и то же для `Microphone`), после чего дать приложению запросить доступ заново.

### Использование

- **Зажми правый ⌘** (клавиша меняется в меню) → говори → отпусти → текст вставится
- Иконка в строке меню: волна — готова; красная пляшет — запись; точки — распознаёт
- Меню по клику: запись мышкой, выбор клавиши, автозапуск при входе
- **Волна у курсора** — во время диктовки рядом с текстовой кареткой появляется
  плашка, столбики которой пляшут от настоящей громкости голоса (если приложение
  не отдаёт каретку — плашка встаёт у указателя мыши). Отключается в меню
- Длинные диктовки режутся по паузам между фразами и склеиваются

### Обновления

В меню видна текущая версия и пункт «Проверить обновления…». Раз в несколько
часов приложение само спрашивает GitHub, не вышла ли новая версия — по сети
уходит только номер версии, больше ничего. Само оно ничего не устанавливает:
покажет уведомление и ссылку на страницу выпуска.

### Ограничения

- Русский язык. Английскую речь модель пишет кириллицей («зэ квик браун фокс»),
  для английского нужен Whisper
- Интернет нужен один раз — скачать модель, дальше офлайн

### Благодарности

- [GigaAM](https://github.com/salute-developers/GigaAM) — модель распознавания, SberDevices (MIT)

### Лицензия

MIT
