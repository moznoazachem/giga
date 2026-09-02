// Окно первого запуска: разрешения в одном месте.
//
// Раньше запросы выстреливали по мере надобности — мониторинг ввода при
// запуске, микрофон при первой записи, вставка при первой вставке, — и со
// стороны это выглядело как «из приложения сыпятся запросы». Теперь одно
// окно: что попросим, зачем, и по кнопке на каждый доступ. Галочки
// обновляются сами, как только тумблер включён в настройках.

import AVFoundation
import AppKit

final class Onboarding: NSObject {
    private var window: NSWindow?
    private var timer: Timer?
    private var header: NSTextField?
    private var marks: [NSTextField] = []
    private var allowButton: NSButton?
    private var axAsked = false          // системный запрос AX уже дёргали?

    private let checks: [() -> Bool] = [
        { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
        { AXIsProcessTrusted() },
    ]

    static var allGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && AXIsProcessTrusted()
    }

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func build() {
        let rows: [(String, String)] = [
            (L("Микрофон", "Microphone"),
             L("записывать голос", "to record your voice")),
            (L("Универсальный доступ", "Accessibility"),
             L("вставлять текст (жать ⌘V за тебя)", "to insert text (pressing ⌘V for you)")),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let h = label(L("Два разрешения, и можно диктовать",
                        "Two permissions and you're set"), size: 16, bold: true)
        header = h
        stack.addArrangedSubview(h)
        stack.addArrangedSubview(label(
            L("Каждое спросит система: включи в её окне тумблер «Giga Pisar».\nГалочки ниже загорятся сами.",
              "macOS will ask for each one: flip the “Giga Pisar” toggle in its dialog.\nThe checkmarks below update on their own."),
            size: 12, bold: false))

        for (name, why) in rows {
            let mark = label("○", size: 15, bold: true)
            mark.textColor = .tertiaryLabelColor
            marks.append(mark)

            let text = label("\(name): \(why)", size: 13, bold: false)

            let row = NSStackView(views: [mark, text])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        // Одна кнопка на всё: жмёшь — разрешения спрашиваются по очереди
        // сами. Раньше у каждой строки была своя кнопка плюс «Закрыть»
        // внизу — три кнопки конфузили, люди жали одну и бросали.
        let allow = NSButton(title: L("Разрешить всё", "Allow everything"),
                             target: self, action: #selector(allowAll))
        allow.bezelStyle = .rounded
        allow.keyEquivalent = "\r"
        allow.controlSize = .large
        allowButton = allow

        let close = NSButton(title: L("Закрыть", "Close"), target: self,
                             action: #selector(closeWindow))
        close.bezelStyle = .rounded

        let btnRow = NSStackView(views: [allow, close])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10
        stack.addArrangedSubview(btnRow)
        stack.setCustomSpacing(22, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        btnRow.centerXAnchor.constraint(equalTo: stack.centerXAnchor).isActive = true

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Giga Pisar"
        w.isReleasedWhenClosed = false
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        window = w
    }

    private func label(_ s: String, size: CGFloat, bold: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return l
    }

    private func refresh() {
        // окно закрыли крестиком — опрашивать больше некого
        if window?.isVisible != true {
            timer?.invalidate()
            return
        }
        for (i, check) in checks.enumerated() {
            let ok = check()
            marks[i].stringValue = ok ? "✓" : "○"
            marks[i].textColor = ok ? .systemGreen : .tertiaryLabelColor
        }
        allowButton?.isHidden = Self.allGranted
        header?.stringValue = Self.allGranted
            ? L("Всё готово: зажми правый ⌘ и говори", "All set: hold right ⌘ and speak")
            : L("Два разрешения, и можно диктовать", "Two permissions and you're set")
        if Self.allGranted { timer?.invalidate() }
    }

    /// Одна кнопка — оба разрешения, по очереди: сначала микрофон
    /// (системный запрос), после ответа — универсальный доступ. Если
    /// какой-то запрос система уже показывала и его закрыли — вместо
    /// повторного запроса открывается нужный раздел настроек.
    @objc private func allowAll() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.askAccessibility() }
            }
            return
        }
        if micStatus != .authorized { openPane("Privacy_Microphone") }
        askAccessibility()
    }

    private func askAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        if axAsked {
            openPane("Privacy_Accessibility")
        } else {
            axAsked = true
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closeWindow() {
        timer?.invalidate()
        window?.orderOut(nil)
    }
}
