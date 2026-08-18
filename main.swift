// Гига — диктовка через GigaAM для macOS.
// Зажми правый ⌘ — говори — отпусти — текст вставится в активное окно.
// Распознавание: локальный сервер ~/projects/gigaam-cli/server.py (порт 8737).

import AVFoundation
import AppKit
import ServiceManagement

let SERVER_URL = URL(string: "http://127.0.0.1:8737/v1/audio/transcriptions")!
let HEALTH_URL = URL(string: "http://127.0.0.1:8737/health")!

// Серверная часть: штатно ставится скриптом install.sh в ~/.giga/,
// запасной вариант — дев-окружение в ~/projects/gigaam-cli/.
let SERVER_DIRS = [
    "\(NSHomeDirectory())/.giga",
    "\(NSHomeDirectory())/projects/gigaam-cli",
]

func findServer() -> (python: String, script: String)? {
    for dir in SERVER_DIRS {
        let py = "\(dir)/.venv/bin/python"
        let script = "\(dir)/server.py"
        if FileManager.default.fileExists(atPath: py),
           FileManager.default.fileExists(atPath: script) {
            return (py, script)
        }
    }
    return nil
}
let WAV_PATH = NSTemporaryDirectory() + "giga_rec.wav"
let MIN_SECONDS = 0.4

// Клавиши-рации на выбор (модификаторы: у них события flagsChanged)
struct Hotkey {
    let id: String
    let title: String
    let keycode: Int64
    let flag: CGEventFlags
}

let HOTKEYS: [Hotkey] = [
    Hotkey(id: "rcmd", title: "Правый ⌘", keycode: 54, flag: .maskCommand),
    Hotkey(id: "ropt", title: "Правый ⌥", keycode: 61, flag: .maskAlternate),
    Hotkey(id: "rctrl", title: "Правый ⌃", keycode: 62, flag: .maskControl),
    Hotkey(id: "fn", title: "Fn (🌐)", keycode: 63, flag: .maskSecondaryFn),
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
    var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setState(.idle)
        buildMenu()
        ensureServer()
        requestInputMonitoring()
    }

    // Просим «Мониторинг ввода» системным диалогом и ждём, пока пользователь
    // включит тумблер — затем сами создаём перехватчик, без перезапуска.
    func requestInputMonitoring() {
        if CGPreflightListenEventAccess() {
            startEventTap()
            return
        }
        CGRequestListenEventAccess() // системный промпт + Гига появляется в списке
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if CGPreflightListenEventAccess() {
                t.invalidate()
                self?.startEventTap()
            }
        }
    }

    // MARK: состояние и иконка

    enum State { case idle, rec, busy }

    func setState(_ s: State) {
        animTimer?.invalidate()
        animTimer = nil
        switch s {
        case .idle:
            statusItem.button?.image = barsImage([5, 9, 13, 9, 5], red: false)
        case .rec:
            statusItem.button?.image = barsImage([6, 11, 14, 11, 6], red: true)
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
                let h = (0..<5).map { _ in CGFloat.random(in: 3...14) }
                self?.statusItem.button?.image = barsImage(h, red: true)
            }
        case .busy:
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

        let header = NSMenuItem(title: "Гига — диктовка (зажми \(currentHotkey().title))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: "Начать/остановить запись", action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())

        // выбор клавиши диктовки
        let keyItem = NSMenuItem(title: "Клавиша диктовки", action: nil, keyEquivalent: "")
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

        // автозапуск при входе
        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            a.messageText = "Не получилось изменить автозапуск"
            a.informativeText = "Добавь вручную: System Settings → General → Login Items. (\(error.localizedDescription))"
            a.runModal()
        }
        buildMenu()
    }

    // MARK: сервер

    func ensureServer() {
        var req = URLRequest(url: HEALTH_URL)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode != 200, let srv = findServer() {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: srv.python)
                p.arguments = [srv.script]
                try? p.run()
            }
        }.resume()
    }

    // MARK: перехват правого ⌘ (CGEventTap с самовосстановлением)

    func startEventTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let app = Unmanaged<App>.fromOpaque(refcon!).takeUnretainedValue()
            // macOS отключил tap за медлительность — включаем обратно сразу
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = app.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            DispatchQueue.main.async { app.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask),
            callback: callback, userInfo: refcon
        ) else {
            let a = NSAlert()
            a.messageText = "Гиге нужен «Мониторинг ввода» (Input Monitoring)"
            a.informativeText = "System Settings → Privacy & Security → Input Monitoring → включи «Гига»."
            a.runModal()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(type: CGEventType, event: CGEvent) {
        let hk = currentHotkey()
        if type == .keyDown {
            if rightCmdDown { stopRecording(abort: true) } // клавиша+буква = шорткат
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == hk.keycode else { return }
        let pressed = event.flags.contains(hk.flag)
        if pressed {
            rightCmdDown = true
            startRecording()
        } else {
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
                    a.messageText = "Гиге нужен доступ к микрофону"
                    a.informativeText = "Системные настройки → Конфиденциальность и безопасность → Микрофон → включи «Гига»."
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
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: WAV_PATH)) else {
            setState(.idle)
            return
        }
        let boundary = "giga-\(UUID().uuidString)"
        var req = URLRequest(url: SERVER_URL)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"rec.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                self?.setState(.idle)
                guard err == nil, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String, !text.isEmpty
                else {
                    self?.flashError()
                    return
                }
                self?.paste(text)
            }
        }.resume()
    }

    func flashError() {
        // короткая красная вспышка иконки вместо алерта
        statusItem.button?.image = barsImage([13, 4, 13, 4, 13], red: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setState(.idle)
        }
    }

    func paste(_ text: String) {
        // Вставляем через буфер (быстро и надёжно), старое содержимое возвращаем.
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Нажать ⌘V за пользователя можно только с разрешением Accessibility.
        let trusted = AXIsProcessTrusted() || CGPreflightPostEventAccess()
        guard trusted else {
            // Системный промпт «Гига would like to control this computer…»
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            let a = NSAlert()
            a.messageText = "Ещё одно разрешение — и всё"
            a.informativeText = "Текст уже в буфере — вставь его сам через ⌘V.\nВ появившемся системном окне нажми «Open System Settings» и включи «Гига» в списке Accessibility."
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let old {
                pb.clearContents()
                pb.setString(old, forType: .string)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory) // без иконки в доке
app.run()
