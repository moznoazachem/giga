// Менюшка Писаря после вставки: «наговорил — глянул — причесал».
//
// Сырой текст уже вставлен в поле, а рядом с курсором появляется меню:
// 1. Собрать мысль · 2. Сократить · 3. Перевести. Цифра, стрелки с Enter
// или клик — Писарь обрабатывает вставленное и ПОДМЕНЯЕТ его прямо в поле,
// до отправки. После замены рядом висит «Вернуть как было», а после
// возврата снова показываются команды — пробуй хоть все по кругу.
//
// Два костюма. В обычных приложениях — системное меню (тёмная тема —
// тёмное, светлая — светлое). В терминале — терминальный: тёмная рамка,
// моноширинный шрифт и «❯» у выбранного пункта, как у менюшек консольных
// программ. Внутрь чужого окна текст не встроить (система не даёт),
// но одеться под соседа — можно.
//
// Меню висит, пока текст не отправлен: исчезает по Enter, по печати,
// по клику мимо или по крестику. В терминалах подмена без ⌘Z: стираем
// вставленное побуквенно (Backspace) и вставляем новое.

import AppKit

final class Chips {
    static let shared = Chips()

    struct Chip {
        let title: String
        let command: String
    }
    static var all: [Chip] {
        [Chip(title: L("Собрать в чёткую мысль", "Compose the thought"),
              command: "собери это в чёткую, ясно скомпонованную мысль"),
         Chip(title: L("Сократить", "Make it shorter"), command: "сократи, сохранив суть"),
         Chip(title: L("Перевести на английский", "Translate to English"),
              command: "переведи на английский")]
    }

    private let panel: NSPanel
    private var onPick: ((String) -> Void)?
    private var onRevert: (() -> Void)?
    private var hideTimer: Timer?
    private var monitors: [Any] = []
    private var rows: [Row] = []
    private var selected = -1        // подсвеченный стрелками пункт; -1 = никакой
    private var isRevertMenu = false
    private var terminalStyle = false
    private var tap: CFMachPort?

    private init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // MARK: строки меню

    /// Строка меню: подсветка при наведении мышью или стрелками.
    /// В системном костюме — синяя пилюля, в терминальном — «❯» и бирюза.
    private final class Row: NSButton {
        var baseTitle = ""
        var terminal = false
        private var hover: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hover { removeTrackingArea(hover) }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .activeAlways],
                                   owner: self)
            addTrackingArea(t)
            hover = t
        }
        override func mouseEntered(with e: NSEvent) { setHighlighted(true) }
        override func mouseExited(with e: NSEvent) { setHighlighted(false) }

        func setHighlighted(_ on: Bool) {
            wantsLayer = true
            if terminal {
                layer?.backgroundColor = nil
                let color: NSColor = on ? .systemTeal : NSColor.white.withAlphaComponent(0.85)
                attributedTitle = NSAttributedString(
                    string: (on ? "❯ " : "  ") + baseTitle,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                                 .foregroundColor: color])
            } else {
                layer?.cornerRadius = 5
                layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : nil
                attributedTitle = NSAttributedString(
                    string: baseTitle,
                    attributes: [.font: NSFont.menuFont(ofSize: 13),
                                 .foregroundColor: on ? NSColor.white : .labelColor])
            }
        }
    }

    private func row(_ title: String, tag: Int, width: CGFloat,
                     action: Selector) -> Row {
        let b = Row(title: title, target: self, action: action)
        b.tag = tag
        b.isBordered = false
        b.alignment = .left
        b.baseTitle = title
        b.terminal = terminalStyle
        b.frame = NSRect(x: 5, y: 0, width: width - 10, height: 24)
        b.setHighlighted(false)
        return b
    }

    // MARK: коробка меню

    /// Системный костюм — размытый материал меню; терминальный — тёмная
    /// плашка с моноширинным шрифтом, чтобы читалась как часть терминала.
    private func makeBox(rows: [NSView], header: String?, width: CGFloat) -> (NSView, NSSize) {
        var y: CGFloat = 6
        let content: NSView
        if terminalStyle {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.97).cgColor
            v.layer?.cornerRadius = 6
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            content = v
        } else {
            let v = NSVisualEffectView()
            v.material = .menu
            v.state = .active
            v.blendingMode = .behindWindow
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor.separatorColor.cgColor
            content = v
        }
        for r in rows.reversed() {
            r.setFrameOrigin(NSPoint(x: r.frame.origin.x, y: y))
            content.addSubview(r)
            y += r.frame.height + 2
        }
        if let header {
            let h = NSTextField(labelWithString: header)
            if terminalStyle {
                h.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
                h.textColor = NSColor.white.withAlphaComponent(0.45)
            } else {
                h.font = .systemFont(ofSize: 11, weight: .semibold)
                h.textColor = .secondaryLabelColor
            }
            h.sizeToFit()
            h.setFrameOrigin(NSPoint(x: 12, y: y + 2))
            content.addSubview(h)
            // крестик: закрыть, если мешает
            let x = NSButton(title: "✕", target: self, action: #selector(closeTapped))
            x.isBordered = false
            x.font = .systemFont(ofSize: 11, weight: .semibold)
            x.contentTintColor = terminalStyle
                ? NSColor.white.withAlphaComponent(0.4) : .tertiaryLabelColor
            x.sizeToFit()
            x.setFrameOrigin(NSPoint(x: width - x.frame.width - 10, y: y + 1))
            content.addSubview(x)
            y += h.frame.height + 8
        }
        let size = NSSize(width: width, height: y + 4)
        return (content, size)
    }

    // MARK: показ

    /// Показать меню команд возле точки набора.
    /// terminal: одеться под терминал (тёмный костюм, моноширинный шрифт).
    func show(near p: NSPoint, terminal: Bool, onPick: @escaping (String) -> Void) {
        hide()
        self.onPick = onPick
        terminalStyle = terminal
        isRevertMenu = false
        let width: CGFloat = terminal ? 250 : 210
        rows = Self.all.enumerated().map { i, chip in
            row("\(i + 1). \(chip.title)", tag: i, width: width, action: #selector(pick(_:)))
        }
        present(header: L("Писарь: нажми цифру", "Pisar: press a number"),
                width: width, near: p, seconds: 180)
    }

    /// После подмены: один пункт «Вернуть как было».
    func showRevert(near p: NSPoint, terminal: Bool, onRevert: @escaping () -> Void) {
        hide()
        self.onRevert = onRevert
        terminalStyle = terminal
        isRevertMenu = true
        let width: CGFloat = terminal ? 230 : 190
        rows = [row(L("1. ↩ Вернуть как было", "1. ↩ Put it back"), tag: 0,
                    width: width, action: #selector(revert))]
        present(header: L("Писарь подменил текст", "Pisar replaced the text"),
                width: width, near: p, seconds: 180)
    }

    private func present(header: String?, width: CGFloat, near p: NSPoint, seconds: Double) {
        let (box, size) = makeBox(rows: rows, header: header, width: width)
        panel.contentView = box
        var origin = NSPoint(x: p.x + 14, y: p.y - size.height - 44)
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        // аварийный таймер; клик мимо — исчезает (глобальный монитор
        // не видит событий нашего же приложения, клик по меню не задевает)
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown],
                                                     handler: { [weak self] _ in self?.hide() }) {
            monitors.append(m)
        }
        selected = -1
        startTap()
    }

    // MARK: клавиши: цифры — выбор, ↑↓ и Enter — тоже, Esc — закрыть

    /// Пока меню видно, клавиши идут через перехватчик: цифры и стрелки
    /// мы съедаем (иначе упали бы в текст), остальное отдаём.
    /// Работает на том же разрешении «Универсальный доступ», что и вставка.
    private func startTap() {
        stopTap()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Chips>.fromOpaque(refcon).takeUnretainedValue()
            return me.handleKey(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: cb,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return } // нет разрешения — меню остаётся мышиным
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard panel.isVisible else { return Unmanaged.passUnretained(event) }
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        switch kc {
        case 125: // ↓
            moveSelection(+1)
            return nil
        case 126: // ↑
            moveSelection(-1)
            return nil
        case 36, 76: // Enter
            if selected >= 0 {
                let i = selected
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.isRevertMenu { self.revert() }
                    else if i < self.rows.count { self.pick(self.rows[i]) }
                }
                return nil
            }
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return Unmanaged.passUnretained(event)
        case 53: // Esc
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return nil
        case 18, 83: // «1» (и на цифровом блоке)
            return pickByNumber(0)
        case 19, 84: // «2»
            return pickByNumber(1)
        case 20, 85: // «3»
            return pickByNumber(2)
        case 51, 55, 56, 58, 59, 61, 62, 63: // Backspace и модификаторы не гасят
            return Unmanaged.passUnretained(event)
        default: // начал печатать — меню уходит, клавиша идёт в текст
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return Unmanaged.passUnretained(event)
        }
    }

    /// Цифра — мгновенный выбор пункта, как в меню консольных программ.
    /// Съедаем клавишу, чтобы цифра не упала в текст.
    private func pickByNumber(_ i: Int) -> Unmanaged<CGEvent>? {
        guard i < rows.count else {
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isRevertMenu { self.revert() }
            else { self.pick(self.rows[i]) }
        }
        return nil
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let next = selected < 0 ? (delta > 0 ? 0 : rows.count - 1)
                                : (selected + delta + rows.count) % rows.count
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selected = next
            for (i, r) in self.rows.enumerated() { r.setHighlighted(i == next) }
        }
    }

    // MARK: действия

    @objc private func closeTapped() { hide() }

    @objc private func pick(_ sender: NSButton) {
        let cb = onPick
        let chip = Self.all[sender.tag]
        hide()
        cb?(chip.command)
    }

    @objc private func revert() {
        let cb = onRevert
        hide()
        cb?()
    }

    func hide() {
        stopTap()
        hideTimer?.invalidate()
        hideTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        rows = []
        selected = -1
        onPick = nil
        onRevert = nil
        panel.orderOut(nil)
    }
}
