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
        let icon: String      // символ SF Symbols, как в системных меню
        let command: String
    }
    static var all: [Chip] {
        [Chip(title: L("Причесать", "Tidy up"), icon: "wand.and.sparkles",
              command: "причеши текст: убери слова-паразиты и повторы, поправь пунктуацию и очевидные ошибки; смысл, порядок мыслей и лексику не меняй"),
         Chip(title: L("Сократить", "Make it shorter"),
              icon: "arrow.down.right.and.arrow.up.left",
              command: "сократи, сохранив суть"),
         Chip(title: L("Перевести на английский", "Translate to English"),
              icon: "translate",
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

    /// Строка меню: значок, название и цифра-подсказка у правого края —
    /// ровно так системное меню показывает шорткаты. Рисуем сами: обычная
    /// кнопка не умеет развести значок и подсказку по разным краям.
    /// Подсветка — при наведении мышью или стрелками: в системном костюме
    /// пилюля цветом системы, в терминальном — «❯» и бирюза.
    private final class Row: NSButton {
        var baseTitle = ""
        var hint = ""            // цифра справа
        var icon: NSImage?
        var terminal = false
        private var lit = false
        private var hover: NSTrackingArea?

        /// Общая на всё меню подложка выделения: системный материал,
        /// который сам знает, как выглядеть на светлом и на тёмном.
        /// Она одна и переезжает к той строке, что сейчас выбрана.
        weak var подложка: NSView?

        static let height: CGFloat = 24
        static let padL: CGFloat = 15    // от края пилюли до значка
        static let padR: CGFloat = 9     // от цифры до правого края пилюли
        static let iconW: CGFloat = 16   // колонка значка — одна на все строки

        static let gap: CGFloat = 7      // от значка до названия

        /// Отступ названия от края пилюли: со значком — с колонкой, без —
        /// вплотную. В терминале колонку занимает «❯».
        static func titleX(withIcon: Bool) -> CGFloat {
            withIcon ? padL + iconW + gap : padL
        }

        var rowFont: NSFont {
            terminal ? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                     : .menuFont(ofSize: 13)
        }

        /// Цифры — моноширинные: они стоят колонкой у правого края,
        /// и в пропорциональном шрифте «1» уезжала относительно «2» и «3».
        var hintFont: NSFont {
            terminal ? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                     : .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        }

        /// Ширина колонки цифр — по ней же выравнивается крестик в шапке.
        static func hintWidth(_ f: NSFont) -> CGFloat {
            NSAttributedString(string: "0", attributes: [.font: f]).size().width
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hover { removeTrackingArea(hover) }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .activeAlways],
                                   owner: self)
            addTrackingArea(t)
            hover = t
        }
        override func mouseEntered(with e: NSEvent) { setLit(true) }
        override func mouseExited(with e: NSEvent) { setLit(false) }

        func setLit(_ on: Bool) {
            lit = on
            if let подложка {
                if on {
                    подложка.frame = frame
                    подложка.isHidden = false
                } else if подложка.frame == frame {
                    // гасим, только если подложка всё ещё под нами:
                    // мышь могла уже уехать на соседнюю строку
                    подложка.isHidden = true
                }
            }
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            // В системном костюме выделение рисует подложка (см. подложка),
            // здесь остаётся только терминальный: там свой тёмный язык.
            if lit, terminal {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            // На выделении текст и значок белые. Подсветка светлая, и на глаз
            // кажется, что тёмная надпись уместнее, — но в системном меню
            // там именно белый: на снимке внутри полосы нет ни одной тёмной
            // точки, только 255,255,255.
            let основной: NSColor = terminal
                ? (lit ? .systemTeal : NSColor.white.withAlphaComponent(0.85))
                : (lit ? .white : .labelColor)
            let тусклый: NSColor = terminal
                ? NSColor.white.withAlphaComponent(0.35)
                : (lit ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor)

            // значок (в терминале вместо него — маркер выбора)
            if terminal {
                if lit {
                    NSAttributedString(string: "❯", attributes: [.font: rowFont, .foregroundColor: основной])
                        .draw(at: NSPoint(x: Self.padL, y: baseline(rowFont)))
                }
            } else if let icon {
                // Цвет символу задаёт палитра, а не заливка поверх: у многих
                // символов свои слои, и ручная подкраска их не берёт —
                // на подсвеченной строке значок оставался тёмным.
                let крашеный = icon.withSymbolConfiguration(.init(paletteColors: [основной])) ?? icon
                // В квадрат символ не вписываем: почти все они шире, чем выше,
                // и от квадрата их плющило. Вписываем по большей стороне
                // и ставим по центру колонки.
                let s = крашеный.size
                let k = min(Self.iconW / s.width, Self.iconW / s.height)
                let w = s.width * k, h = s.height * k
                крашеный.draw(in: NSRect(x: Self.padL + (Self.iconW - w) / 2,
                                         y: (bounds.height - h) / 2, width: w, height: h))
            }

            let t = NSAttributedString(string: baseTitle,
                                       attributes: [.font: rowFont, .foregroundColor: основной])
            t.draw(at: NSPoint(x: Self.titleX(withIcon: icon != nil || terminal), y: baseline(rowFont)))

            if !hint.isEmpty {
                let h = NSAttributedString(string: hint,
                                           attributes: [.font: hintFont, .foregroundColor: тусклый])
                h.draw(at: NSPoint(x: bounds.width - Self.padR - h.size().width,
                                   y: baseline(hintFont)))
            }
        }

        /// Низ строки текста, чтобы она встала по центру пилюли.
        private func baseline(_ f: NSFont) -> CGFloat {
            (bounds.height - (f.ascender - f.descender)) / 2
        }
    }

    private func row(_ title: String, icon: String?, hint: String, tag: Int,
                     action: Selector) -> Row {
        let b = Row(title: title, target: self, action: action)
        b.tag = tag
        b.isBordered = false
        b.baseTitle = title
        b.hint = hint
        b.terminal = terminalStyle
        // в терминале значков нет: там свой язык — «❯» и моноширинный шрифт
        if !terminalStyle, let icon {
            b.icon = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        b.setLit(false)
        return b
    }

    /// Ширина меню по самой длинной строке: раньше она была задана числом,
    /// и длинный перевод почти упирался в край.
    private func width(rows: [Row], header: String?) -> CGFloat {
        var w: CGFloat = 0
        for r in rows {
            let t = NSAttributedString(string: r.baseTitle, attributes: [.font: r.rowFont])
            let h = NSAttributedString(string: r.hint, attributes: [.font: r.hintFont])
            w = max(w, Row.titleX(withIcon: r.icon != nil || r.terminal) + t.size().width
                       + 24 + h.size().width + Row.padR)
        }
        if let header {
            let f: NSFont = terminalStyle ? .monospacedSystemFont(ofSize: 11, weight: .semibold)
                                          : .systemFont(ofSize: 11, weight: .semibold)
            w = max(w, NSAttributedString(string: header, attributes: [.font: f]).size().width
                       + Row.padL + Row.padR + 34)
        }
        return min(max(ceil(w) + Self.padBox * 2, 200), 420)
    }

    // MARK: коробка меню

    /// Поле от края коробки до пилюли строки — как у системных меню:
    /// подсветка не доезжает до самого края.
    private static let padBox: CGFloat = 5
    private static let radius: CGFloat = 13   // как у системного меню на 26-й

    /// Три костюма фона. На macOS 26 — стекло, из которого система рисует
    /// свои меню (материал .menu рядом с настоящим меню выглядит серой
    /// плашкой). До 26-й — тот самый материал. В терминале — тёмная плашка
    /// с моноширинным шрифтом, чтобы читалась как часть терминала.
    private func makeBox(rows: [Row], header: String?, width: CGFloat) -> (NSView, NSSize) {
        // Строки и шапка живут в отдельном слое: у стекла своё нутро
        // (contentView), и класть их прямо в фон нельзя.
        let holder = NSView()
        var y = Self.padBox

        // Подложка выделения — системный материал .selection: тот же, каким
        // система метит выбранную строку в меню и списках. Простая заливка
        // акцентом с прозрачностью сходилась с ним на светлом фоне и
        // разъезжалась на тёмном: у системы выделение вибрантное, а не
        // просто полупрозрачное. Кладём её первой — она должна быть под
        // строками, иначе накроет их текст.
        var подложка: NSView?
        if !terminalStyle {
            let v = NSVisualEffectView()
            v.material = .selection
            v.state = .active
            v.isEmphasized = true
            v.blendingMode = .behindWindow
            v.wantsLayer = true
            v.layer?.cornerRadius = 6
            v.layer?.masksToBounds = true
            v.isHidden = true
            holder.addSubview(v)
            подложка = v
        }

        for r in rows.reversed() {
            r.подложка = подложка
            r.frame = NSRect(x: Self.padBox, y: y,
                             width: width - Self.padBox * 2, height: Row.height)
            holder.addSubview(r)
            y += Row.height
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
            // шапку ставим по левому краю названий, а не по краю коробки
            h.setFrameOrigin(NSPoint(x: Self.padBox + Row.padL, y: y + 5))
            holder.addSubview(h)

            // крестик: закрыть, если мешает
            let x = NSButton(title: "", target: self, action: #selector(closeTapped))
            x.isBordered = false
            x.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            x.imagePosition = .imageOnly
            x.contentTintColor = terminalStyle
                ? NSColor.white.withAlphaComponent(0.4) : .tertiaryLabelColor
            // крестик стоит на той же вертикали, что и колонка цифр
            let колонка = Row.hintWidth(rows.first?.hintFont ?? .menuFont(ofSize: 13))
            let центр = width - Self.padBox - Row.padR - колонка / 2
            x.frame = NSRect(x: центр - 7, y: y + 3, width: 14, height: 14)
            holder.addSubview(x)
            y += h.frame.height + 9
        }

        let size = NSSize(width: width, height: y + Self.padBox)
        holder.frame = NSRect(origin: .zero, size: size)

        let content: NSView
        if terminalStyle {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.97).cgColor
            v.layer?.cornerRadius = Self.radius
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            v.addSubview(holder)
            content = v
        } else if #available(macOS 26.0, *) {
            let v = NSGlassEffectView()
            v.cornerRadius = Self.radius
            v.contentView = holder
            content = v
        } else {
            let v = NSVisualEffectView()
            v.material = .menu
            v.state = .active
            v.blendingMode = .behindWindow
            // Размытие фона живёт по форме ОКНА, а не по скруглению слоя:
            // без этой маски по углам плашки торчали белые квадратные уши.
            v.maskImage = Self.roundedMask(radius: Self.radius)
            v.wantsLayer = true
            v.layer?.cornerRadius = Self.radius
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 1
            v.layer?.borderColor = NSColor.separatorColor.cgColor
            v.addSubview(holder)
            content = v
        }
        content.frame = NSRect(origin: .zero, size: size)
        return (content, size)
    }

    /// Скруглённая маска для размытия под меню. Тянущаяся: середина
    /// растягивается, углы остаются круглыми.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 2
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    // MARK: показ

    /// Показать меню команд возле точки набора.
    /// terminal: одеться под терминал (тёмный костюм, моноширинный шрифт).
    func show(near p: NSPoint, terminal: Bool, onPick: @escaping (String) -> Void) {
        hide()
        self.onPick = onPick
        terminalStyle = terminal
        isRevertMenu = false
        rows = Self.all.enumerated().map { i, chip in
            row(chip.title, icon: chip.icon, hint: "\(i + 1)", tag: i,
                action: #selector(pick(_:)))
        }
        present(header: L("Писарь: нажми цифру", "Pisar: press a number"),
                near: p, seconds: 180)
    }

    /// После подмены: один пункт «Вернуть как было».
    func showRevert(near p: NSPoint, terminal: Bool, onRevert: @escaping () -> Void) {
        hide()
        self.onRevert = onRevert
        terminalStyle = terminal
        isRevertMenu = true
        rows = [row(L("Вернуть как было", "Put it back"), icon: "arrow.uturn.backward",
                    hint: "1", tag: 0, action: #selector(revert))]
        present(header: L("Писарь подменил текст", "Pisar replaced the text"),
                near: p, seconds: 180)
    }

    private func present(header: String?, near p: NSPoint, seconds: Double) {
        let (box, size) = makeBox(rows: rows, header: header,
                                  width: width(rows: rows, header: header))
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
            return pickByNumber(0, event)
        case 19, 84: // «2»
            return pickByNumber(1, event)
        case 20, 85: // «3»
            return pickByNumber(2, event)
        case 55, 56, 58, 59, 61, 62, 63: // модификаторы меню не гасят
            return Unmanaged.passUnretained(event)
        case 51, 117: // Backspace и Delete: стирает текст — подсказка не нужна
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return Unmanaged.passUnretained(event)
        default: // начал печатать — меню уходит, клавиша идёт в текст
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return Unmanaged.passUnretained(event)
        }
    }

    /// Цифра — мгновенный выбор пункта, как в меню консольных программ.
    /// Съедаем клавишу, чтобы цифра не упала в текст.
    private func pickByNumber(_ i: Int, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard i < rows.count else {
            // цифры, которой нет в меню: прячемся, а клавишу отдаём тексту
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return Unmanaged.passUnretained(event)
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
            for (i, r) in self.rows.enumerated() { r.setLit(i == next) }
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
