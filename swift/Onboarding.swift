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
    private var buttons: [NSButton] = []
    private var asked = [false, false]   // уже дёргали системный запрос?

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
             L("вставлять текст — нажимать ⌘V за тебя", "to insert text — pressing ⌘V for you")),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let h = label(L("Два разрешения — и можно диктовать",
                        "Two permissions and you're set"), size: 16, bold: true)
        header = h
        stack.addArrangedSubview(h)
        stack.addArrangedSubview(label(
            L("Каждое спросит система — включи в её окне тумблер «Giga Pisar».\nГалочки ниже загорятся сами.",
              "macOS will ask for each one — flip the “Giga Pisar” toggle in its dialog.\nThe checkmarks below update on their own."),
            size: 12, bold: false))

        for (i, (name, why)) in rows.enumerated() {
            let mark = label("○", size: 15, bold: true)
            mark.textColor = .tertiaryLabelColor
            marks.append(mark)

            let text = label("\(name) — \(why)", size: 13, bold: false)

            let b = NSButton(title: L("Разрешить", "Allow"), target: self,
                             action: #selector(allow(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            buttons.append(b)

            let row = NSStackView(views: [mark, text, NSView(), b])
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        let close = NSButton(title: L("Закрыть", "Close"), target: self,
                             action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        stack.addArrangedSubview(close)

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
        for (i, check) in checks.enumerated() {
            let ok = check()
            marks[i].stringValue = ok ? "✓" : "○"
            marks[i].textColor = ok ? .systemGreen : .tertiaryLabelColor
            buttons[i].isHidden = ok
        }
        header?.stringValue = Self.allGranted
            ? L("Всё готово — зажми правый ⌘ и говори", "All set — hold right ⌘ and speak")
            : L("Два разрешения — и можно диктовать", "Two permissions and you're set")
        if Self.allGranted { timer?.invalidate() }
    }

    /// Первый клик — системный запрос; повторный (если окно запроса закрыли
    /// или доступ уже отклоняли) — сразу нужный раздел настроек.
    @objc private func allow(_ sender: NSButton) {
        let again = asked[sender.tag]
        asked[sender.tag] = true
        if sender.tag == 0 {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else { openPane("Privacy_Microphone") }
        } else {
            if again { openPane("Privacy_Accessibility") } else {
                _ = AXIsProcessTrustedWithOptions(
                    ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
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
