// Гига Писарь — диктовка через GigaAM для macOS.
// Зажми правый ⌘ — говори — отпусти — текст вставится в активное окно.
// Распознавание идёт внутри самого приложения (Recognizer.swift): ни питона,
// ни ffmpeg, ни какого-либо сервера рядом не нужно.

import AVFoundation
import AppKit
import ServiceManagement

// Язык интерфейса берём у системы: русская система — русские надписи,
// любая другая — английские. Имя приложения (Giga Pisar) не переводится.
let uiIsRussian: Bool = (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")

/// Выбирает надпись по языку системы: L(<по-русски>, <по-английски>).
func L(_ ru: String, _ en: String) -> String { uiIsRussian ? ru : en }

// Где искать файлы модели. Сначала внутри самого приложения — так его можно
// отдать человеку одним куском; потом обычные места на диске.
func findModelDir() -> String? {
    var places: [String] = []
    if let res = Bundle.main.resourcePath { places.append(res + "/model") }
    places.append("\(NSHomeDirectory())/.giga/model")
    for dir in places
    where FileManager.default.fileExists(atPath: "\(dir)/\(Recognizer.modelName).yaml") {
        return dir
    }
    return nil
}
let APP_VERSION = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
let WAV_PATH = NSTemporaryDirectory() + "giga_rec.wav"
let MIN_SECONDS = 0.4

// Клавиши-рации на выбор (модификаторы: у них события flagsChanged)
struct Hotkey {
    let id: String
    let title: String
    let keycode: UInt16
    let flag: NSEvent.ModifierFlags
}

let HOTKEYS: [Hotkey] = [
    Hotkey(id: "rcmd", title: L("Правый ⌘", "Right ⌘"), keycode: 54, flag: .command),
    Hotkey(id: "ropt", title: L("Правый ⌥", "Right ⌥"), keycode: 61, flag: .option),
    Hotkey(id: "rctrl", title: L("Правый ⌃", "Right ⌃"), keycode: 62, flag: .control),
    Hotkey(id: "fn", title: "Fn (🌐)", keycode: 63, flag: .function),
]

func currentHotkey() -> Hotkey {
    let id = UserDefaults.standard.string(forKey: "hotkey") ?? "rcmd"
    return HOTKEYS.first { $0.id == id } ?? HOTKEYS[0]
}

// MARK: - Иконки (рисуем векторно, template → ЧБ под тему строки меню)

func barsImage(_ heights: [CGFloat], red: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        let color = red ? NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1) : NSColor.black
        color.setFill()
        for (i, h) in heights.enumerated() {
            let r = NSRect(x: 1 + CGFloat(i) * 4.2, y: 9 - h / 2, width: 2.8, height: h)
            NSBezierPath(roundedRect: r, xRadius: 1.3, yRadius: 1.3).fill()
        }
        return true
    }
    img.isTemplate = !red
    return img
}

func dotsImage(_ count: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        for i in 0..<count {
            let r = NSRect(x: 1.2 + CGFloat(i) * 6.5, y: 7.2, width: 3.6, height: 3.6)
            NSBezierPath(ovalIn: r).fill()
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Приложение

final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var recorder: AVAudioRecorder?
    var recStart: Date?
    var rightCmdDown = false
    var cancelled = false
    var animTimer: Timer?

    /// Окно с разрешениями (первый запуск и пункт меню).
    let onboarding = Onboarding()

    /// Модель. Грузится один раз в фоне; recognizer трогаем только из recognizerQueue.
    var recognizer: Recognizer?
    let recognizerQueue = DispatchQueue(label: "ru.panda.giga.recognizer")

    /// Плашка с волной у места набора (выключается в меню).
    let wave = WavePanel()
    var waveEnabled: Bool { UserDefaults.standard.object(forKey: "wavePanel") as? Bool ?? true }

    /// Номер версии с GitHub, если она новее нашей.
    var updateAvailable: String?

    /// Последняя удачная диктовка — страховка на случай «курсор был не в поле».
    var lastText: String?



    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setState(.idle)
        buildMenu()
        loadModel()
        startKeyMonitors()
        if !Onboarding.allGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onboarding.show()
            }
        }
        // обновления: раз при запуске (чуть погодя) и дальше каждые 6 часов
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkUpdates(silent: true)
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkUpdates(silent: true)
        }
    }

    enum State { case idle, rec, busy }

    func setState(_ s: State) {
        animTimer?.invalidate()
        animTimer = nil
        switch s {
        case .idle:
            statusItem.button?.image = barsImage([5, 9, 13, 9, 5], red: false)
            wave.hide()
        case .rec:
            // Анимация виртуальная: нажал — сразу пошла. Стиль — эквалайзер:
            // столбики прыгают независимо. От настоящей громкости отказались:
            // у измерителя Apple инерция, и честная волна выглядела вялой.
            statusItem.button?.image = barsImage([6, 11, 14, 11, 6], red: true)
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self else { return }
                let h = (0..<5).map { _ in CGFloat.random(in: 3...14) }
                self.statusItem.button?.image = barsImage(h, red: true)
                self.wave.tick()
            }
        case .busy:
            wave.busy() // серые столбики: «услышал, распознаю»
            var tick = 0
            statusItem.button?.image = dotsImage(1)
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                tick += 1
                self?.statusItem.button?.image = dotsImage(tick % 3 + 1)
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        // включённостью пунктов управляем сами: серые должны быть серыми,
        // даже если у них есть подменю
        menu.autoenablesItems = false

        let header = NSMenuItem(title: L("Гига Писарь — диктовка (зажми \(currentHotkey().title))",
                                     "Giga Pisar — dictation (hold \(currentHotkey().title))"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: L("Начать/остановить запись", "Start / stop recording"), action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())

        // выбор клавиши диктовки
        let keyItem = NSMenuItem(title: L("Клавиша диктовки", "Dictation key"), action: nil, keyEquivalent: "")
        let keyMenu = NSMenu()
        for hk in HOTKEYS {
            let item = NSMenuItem(title: hk.title, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hk.id
            item.state = (hk.id == currentHotkey().id) ? .on : .off
            keyMenu.addItem(item)
        }
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)

        // плашка с волной у места набора
        let waveItem = NSMenuItem(title: L("Волна у курсора", "Wave near cursor"),
                                  action: #selector(toggleWave), keyEquivalent: "")
        waveItem.target = self
        waveItem.state = waveEnabled ? .on : .off
        menu.addItem(waveItem)

        // цвет волны — без волны выбирать нечего
        let colorItem = NSMenuItem(title: L("Цвет волны", "Wave color"), action: nil, keyEquivalent: "")
        colorItem.isEnabled = waveEnabled
        let colorMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: "waveColor") ?? "dark"
        for (id, name) in [("dark", L("Тёмный", "Dark")),
                           ("green", L("Зелёный", "Green")),
                           ("red", L("Красный", "Red"))] {
            let it = NSMenuItem(title: name, action: #selector(pickWaveColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = id
            it.state = current == id ? .on : .off
            colorMenu.addItem(it)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // автозапуск при входе
        let login = NSMenuItem(title: L("Запускать при входе", "Open at login"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        if WavePanel.pinned != nil {
            let unpin = NSMenuItem(title: L("Вернуть волну к курсору", "Wave: follow cursor again"),
                                   action: #selector(unpinWave), keyEquivalent: "")
            unpin.target = self
            unpin.isEnabled = waveEnabled
            menu.addItem(unpin)
        }

        let lastItem = NSMenuItem(title: L("Скопировать последнюю диктовку", "Copy last dictation"),
                                  action: #selector(copyLast), keyEquivalent: "")
        lastItem.target = self
        lastItem.isEnabled = lastText != nil
        menu.addItem(lastItem)

        let perms = NSMenuItem(title: L("Доступы…", "Permissions…"),
                               action: #selector(showOnboarding), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)

        menu.addItem(NSMenuItem.separator())

        // версия и обновления
        if let upd = updateAvailable {
            let it = NSMenuItem(title: L("Доступна версия \(upd) — скачать", "Version \(upd) available — download"),
                                action: #selector(openReleases), keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        let ver = NSMenuItem(title: L("Версия \(APP_VERSION)", "Version \(APP_VERSION)"), action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        let check = NSMenuItem(title: L("Проверить обновления…", "Check for updates…"),
                               action: #selector(checkUpdatesManual), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: L("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func menuToggle() {
        if recorder != nil { stopRecording(abort: false) } else { startRecording() }
    }

    @objc func pickHotkey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "hotkey")
        buildMenu() // обновить галочки и заголовок
    }

    @objc func showOnboarding() { onboarding.show() }

    @objc func copyLast() {
        guard let t = lastText else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t, forType: .string)
        Toast.shared.show(L("В буфере — нажми ⌘V", "On the clipboard — press ⌘V"), seconds: 2)
    }

    @objc func pickWaveColor(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "waveColor")
        buildMenu()
    }

    @objc func unpinWave() {
        WavePanel.pinned = nil
        buildMenu()
    }

    @objc func toggleWave() {
        UserDefaults.standard.set(!waveEnabled, forKey: "wavePanel")
        if !waveEnabled { wave.hide() }
        buildMenu()
    }

    @objc func openReleases() {
        if let url = URL(string: RELEASES_PAGE) { NSWorkspace.shared.open(url) }
    }

    @objc func checkUpdatesManual() { checkUpdates(silent: false) }

    /// silent — фоновая проверка: молчит, если новостей нет, и об одной и той
    /// же версии напоминает окном только один раз (дальше — пункт в меню).
    func checkUpdates(silent: Bool) {
        fetchLatestVersion { [weak self] latest in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let latest else {
                    if !silent {
                        let a = NSAlert()
                        a.messageText = L("Не удалось проверить", "Couldn't check")
                        a.informativeText = L("GitHub не ответил. Попробуй позже.",
                                              "GitHub didn't respond. Try again later.")
                        a.runModal()
                    }
                    return
                }
                guard isNewerVersion(latest, than: APP_VERSION) else {
                    self.updateAvailable = nil
                    if !silent {
                        let a = NSAlert()
                        a.messageText = L("У тебя последняя версия", "You're up to date")
                        a.informativeText = L("Версия \(APP_VERSION) — новее на GitHub нет.",
                                              "Version \(APP_VERSION) is the latest.")
                        a.runModal()
                    }
                    return
                }
                self.updateAvailable = latest
                self.buildMenu()
                let seen = UserDefaults.standard.string(forKey: "lastUpdateNotified")
                if !silent || seen != latest {
                    UserDefaults.standard.set(latest, forKey: "lastUpdateNotified")
                    let a = NSAlert()
                    a.messageText = L("Вышла версия \(latest)", "Version \(latest) is out")
                    a.informativeText = L("У тебя \(APP_VERSION). Скачать со страницы выпуска?",
                                          "You have \(APP_VERSION). Download from the releases page?")
                    a.addButton(withTitle: L("Скачать", "Download"))
                    a.addButton(withTitle: L("Позже", "Later"))
                    if a.runModal() == .alertFirstButtonReturn { self.openReleases() }
                }
            }
        }
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = L("Не получилось изменить автозапуск", "Couldn't change the login setting")
            a.informativeText = L("Добавь вручную: System Settings → General → Login Items. (\(error.localizedDescription))",
                                  "Add it manually: System Settings → General → Login Items. (\(error.localizedDescription))")
            a.runModal()
        }
        buildMenu()
    }

    // MARK: сервер

    func loadModel() {
        guard let dir = findModelDir() else {
            DispatchQueue.main.async { [weak self] in self?.complainNoModel() }
            return
        }
        recognizerQueue.async { [weak self] in
            do {
                self?.recognizer = try Recognizer(modelDir: dir)
            } catch {
                NSLog("Гига Писарь: модель не загрузилась — \(error)")
                DispatchQueue.main.async { self?.complainNoModel() }
            }
        }
    }

    func complainNoModel() {
        let a = NSAlert()
        a.messageText = L("Не нашёл файлы модели", "Speech model not found")
        a.informativeText = L("Ожидались в ~/.giga/model. Поставь их скриптом install.sh из репозитория.",
                              "Expected in ~/.giga/model. Install them with install.sh from the repository.")
        a.runModal()
    }

    // MARK: перехват правого ⌘ — без разрешения «Мониторинг ввода»
    //
    // macOS охраняет СОДЕРЖИМОЕ набора: следить за обычными клавишами без
    // Input Monitoring нельзя. А состояние модификаторов (⌘/⌥/⌃/Fn)
    // содержимым не считается — NSEvent отдаёт его любому приложению.
    // Наши клавиши-рации все модификаторы, так что перехватчик всей
    // клавиатуры был избыточен; проверено опытом: flagsChanged приходит
    // без разрешений, keyDown — нет.

    func startKeyMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
        }
        // когда активны мы сами (открыто наше меню) — события идут локально
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
            return e
        }
        // Буква, нажатая при зажатой рации, значит «это шорткат, не диктовка» —
        // тогда запись отменяется. Такие события система отдаёт только
        // с разрешением «Универсальный доступ» (оно и так нужно для вставки);
        // пока его нет, просто не работает эта мелочь, а диктовка работает.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self, self.rightCmdDown else { return }
            self.stopRecording(abort: true)
        }
    }

    func handleFlags(_ e: NSEvent) {
        let hk = currentHotkey()
        guard e.keyCode == hk.keycode else { return }
        let pressed = e.modifierFlags.contains(hk.flag)
        if pressed, !rightCmdDown {
            rightCmdDown = true
            startRecording()
        } else if !pressed, rightCmdDown {
            rightCmdDown = false
            stopRecording(abort: false)
        }
    }

    // MARK: запись (родной AVAudioRecorder, 16 кГц моно wav)

    func startRecording() {
        guard recorder == nil else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    let a = NSAlert()
                    a.messageText = L("Гига Писарю нужен доступ к микрофону", "Giga Pisar needs microphone access")
                    a.informativeText = L("Системные настройки → Конфиденциальность и безопасность → Микрофон → включи «Giga Pisar».",
                                  "System Settings → Privacy & Security → Microphone → turn on “Giga Pisar”.")
                    a.runModal()
                    return
                }
                self?.beginRecording()
            }
        }
    }

    func beginRecording() {
        guard recorder == nil else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: URL(fileURLWithPath: WAV_PATH), settings: settings)
            r.record()
            recorder = r
            recStart = Date()
            cancelled = false
            setState(.rec)
            if waveEnabled { wave.show(near: typingAnchor()) }
        } catch {
            setState(.idle)
        }
    }

    func stopRecording(abort: Bool) {
        guard let r = recorder else { return }
        cancelled = abort
        r.stop()
        recorder = nil
        let dur = Date().timeIntervalSince(recStart ?? Date())
        if cancelled || dur < MIN_SECONDS {
            setState(.idle)
            return
        }
        transcribe()
    }

    // MARK: распознавание и вставка

    func transcribe() {
        setState(.busy)
        recognizerQueue.async { [weak self] in
            guard let r = self?.recognizer else {
                // Модель не нашлась вовсе (про это уже было окно при запуске).
                // Если она ещё грузилась, мы сюда не попадём: загрузка стоит
                // в этой же очереди первой, и работа дождалась её сама.
                DispatchQueue.main.async {
                    self?.setState(.idle)
                    self?.flashError()
                }
                return
            }
            let текст: String
            do {
                текст = try r.transcribe(wavPath: WAV_PATH)
            } catch {
                NSLog("Гига Писарь: не распознал — \(error)")
                DispatchQueue.main.async {
                    self?.setState(.idle)
                    self?.flashError()
                }
                return
            }
            DispatchQueue.main.async {
                self?.setState(.idle)
                if текст.isEmpty { self?.flashError() } else { self?.paste(текст) }
            }
        }
    }

    func flashError() {
        // короткая красная вспышка иконки вместо алерта
        statusItem.button?.image = barsImage([13, 4, 13, 4, 13], red: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setState(.idle)
        }
    }

    func paste(_ text: String) {
        lastText = text
        buildMenu() // в меню оживает «Скопировать последнюю диктовку»

        // Вставляем через буфер (быстро и надёжно), старое содержимое возвращаем.
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Есть ли куда вставлять? Каретка видна — курсор точно в тексте.
        // Не видна — либо поля нет, либо приложение её не показывает
        // (бывает у построенных на Electron): тогда ⌘V всё равно нажмём,
        // но буфер НЕ затираем и подсказываем — так диктовка не теряется.
        let вПоле = caretRect() != nil
        // Нажать ⌘V за пользователя можно только с разрешением Accessibility.
        let trusted = AXIsProcessTrusted() || CGPreflightPostEventAccess()
        guard trusted else {
            // Системный промпт «Giga Pisar would like to control this computer…»
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            let a = NSAlert()
            a.messageText = L("Ещё одно разрешение — и всё", "One more permission and you're set")
            a.informativeText = L("Текст уже в буфере — вставь его сам через ⌘V.\nВ появившемся системном окне нажми «Open System Settings» и включи «Giga Pisar» в списке Accessibility.",
                                  "The text is already on the clipboard — paste it with ⌘V.\nIn the system dialog, click “Open System Settings” and turn on “Giga Pisar” under Accessibility.")
            a.runModal()
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // V
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        if вПоле {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let old {
                    pb.clearContents()
                    pb.setString(old, forType: .string)
                }
            }
        } else {
            Toast.shared.show(L("Курсор был не в тексте — диктовка в буфере, нажми ⌘V",
                                "The cursor wasn't in a text field — your dictation is on the clipboard, press ⌘V"))
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory) // без иконки в доке
app.run()
