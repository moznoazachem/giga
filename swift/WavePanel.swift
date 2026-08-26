// Плашка с волной голоса рядом с местом набора текста.
//
// Волна в строке меню наверху видна плохо, когда экран большой и смотришь
// на курсор. Эта плашка появляется у текстовой каретки (спрашиваем через
// Accessibility, разрешение и так есть), а если каретку не отдали —
// у указателя мыши. Анимация виртуальная, в стиле эквалайзера: она говорит
// «идёт запись», а не показывает громкость — честная громкость выглядела
// вялой из-за инерции измерителя Apple.

import AppKit

/// Где сейчас набирается текст. По убыванию точности:
/// каретка активного поля → низ самого поля → указатель мыши.
func typingAnchor() -> NSPoint {
    if let p = typingAnchorIfKnown(log: true) { return p }
    NSLog("Гига якорь: мышь \(NSEvent.mouseLocation)")
    return NSEvent.mouseLocation
}

/// Якорь без запасного варианта «мышь» — для слежения во время записи:
/// за окном с кареткой плашка ходить должна, а за мышью — нет.
func typingAnchorIfKnown(log: Bool = false) -> NSPoint? {
    if let p = caretPoint() {
        if log { NSLog("Гига якорь: каретка \(p)") }
        return p
    }
    if let f = focusedFieldFrame() {
        if log { NSLog("Гига якорь: поле \(f)") }
        return NSPoint(x: f.midX, y: f.minY + 30)
    }
    return nil
}

// MARK: - разговор с Accessibility

/// Элемент, в котором сейчас клавиатурный фокус.
private func axFocusedElement() -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                        "AXFocusedUIElement" as CFString,
                                        &ref) == .success,
          let f = ref, CFGetTypeID(f) == AXUIElementGetTypeID()
    else { return nil }
    return (f as! AXUIElement)
}

/// Положение курсора набора (выделения) в фокусном элементе.
private func axSelectedRange(_ el: AXUIElement) -> CFRange? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXSelectedTextRange" as CFString,
                                        &ref) == .success,
          let v = ref, CFGetTypeID(v) == AXValueGetTypeID()
    else { return nil }
    var r = CFRange()
    guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
    return r
}

/// AX отдаёт координаты от левого ВЕРХНЕГО угла главного экрана,
/// кокоа считает от левого нижнего — переворачиваем.
private func axFlip(_ rect: CGRect) -> NSRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height,
                  width: rect.width, height: rect.height)
}

/// Мусор или настоящее место? Настоящее лежит на каком-то из экранов.
private func axOnScreen(_ r: NSRect) -> Bool {
    NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).intersects(r) }
}

/// Границы куска текста, если приложение их честно отдало.
private func axBounds(_ el: AXUIElement, _ range: CFRange) -> NSRect? {
    var r = range
    guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
    var ref: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        el, "AXBoundsForRange" as CFString, rv, &ref) == .success,
          let b = ref, CFGetTypeID(b) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(b as! AXValue, .cgRect, &rect) else { return nil }
    // Настоящая каретка — коробочка высотой со строку текста. Нулевые
    // и небоскрёбные прямоугольники — ложь (терминалы любят отдать
    // нулевую точку в углу экрана, и плашка уезжала туда за ней).
    guard rect.height >= 4, rect.height <= 300 else { return nil }
    let out = axFlip(rect)
    guard axOnScreen(out) else { return nil }
    return out
}

/// Есть ли сейчас фокус в текстовом поле (даже если оно скрывает,
/// ГДЕ каретка): по этому решаем, вставится ли ⌘V.
func hasTextFocus() -> Bool {
    guard let el = axFocusedElement() else { return false }
    return axSelectedRange(el) != nil
}

/// Точка текстовой каретки (низ) в кокоа-координатах, если приложение
/// отдаёт её честно. Пустое выделение часто отдаёт мусорные границы —
/// тогда спрашиваем про соседний символ и берём его КРАЙ, обращённый
/// к курсору. Ответы шире 60 пунктов — враньё (терминалы любят отдать
/// коробку во всю строку, и плашка вставала в её середину, а не у курсора).
func caretPoint() -> NSPoint? {
    guard let el = axFocusedElement(), let sel = axSelectedRange(el) else { return nil }
    // сам пустой курсор — узкая коробочка
    if let r = axBounds(el, sel), r.width <= 60 {
        return NSPoint(x: r.midX, y: r.minY)
    }
    // символ ПЕРЕД кареткой: курсор у его правого края
    if sel.location > 0,
       let r = axBounds(el, CFRange(location: sel.location - 1, length: 1)), r.width <= 60 {
        return NSPoint(x: r.maxX, y: r.minY)
    }
    // символ ПОСЛЕ каретки: курсор у его левого края
    if let r = axBounds(el, CFRange(location: sel.location, length: 1)), r.width <= 60 {
        return NSPoint(x: r.minX, y: r.minY)
    }
    return nil
}

/// Рамка фокусного поля — запасной якорь, когда каретку скрывают.
func focusedFieldFrame() -> NSRect? {
    guard let el = axFocusedElement() else { return nil }
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &ref) == .success,
          let v = ref, CFGetTypeID(v) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
    let out = axFlip(rect)
    guard axOnScreen(out) else { return nil }
    return out
}

final class WaveView: NSView {
    var busy = false
    private var heights: [CGFloat] = [0.4, 0.6, 0.8, 0.6, 0.4]

    // Перетаскивание ведём сами, без isMovableByWindowBackground:
    // так «пользователь перетащил» — это буквально нажатие мышью
    // по плашке с движением, и спутать его с программным переездом
    // (чем страдали 2.3 и первая 2.4) невозможно по построению.
    private var dragMouse: NSPoint?
    private var dragOrigin: NSPoint?
    private var dragged = false
    var dragging: Bool { dragMouse != nil }

    override func mouseDown(with e: NSEvent) {
        dragMouse = NSEvent.mouseLocation
        dragOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let m0 = dragMouse, let o0 = dragOrigin, let w = window else { return }
        let m = NSEvent.mouseLocation
        if abs(m.x - m0.x) + abs(m.y - m0.y) > 3 { dragged = true }
        w.setFrameOrigin(NSPoint(x: o0.x + m.x - m0.x, y: o0.y + m.y - m0.y))
    }

    override func mouseUp(with e: NSEvent) {
        if dragged, let w = window {
            WavePanel.pinned = w.frame.origin
            NSLog("Гига волна: перетащена и прибита к \(w.frame.origin)")
            // в меню появляется пункт «Вернуть волну к курсору»
            (NSApp.delegate as? App)?.buildMenu()
        }
        dragMouse = nil; dragOrigin = nil; dragged = false
    }

    /// Один в один как иконка в трее: каждый столбик каждый кадр прыгает
    /// на случайную высоту, без сглаживания. Оба кормит один таймер,
    /// так что пляшут они синхронно по темпу.
    func tick() {
        for i in 0..<heights.count {
            heights[i] = CGFloat.random(in: 0.2...1.0)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // светлая плашка: белая, с тонкой окантовкой, чтобы читалась
        // и на белом фоне, и на тёмном
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.96).setFill()
        pill.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        let bars = heights.count
        let barW: CGFloat = 4
        let gap: CGFloat = 4
        let totalW = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
        let x0 = (bounds.width - totalW) / 2
        let maxH = bounds.height - 8

        // цвет столбиков выбирается в меню приложения
        let chosen = UserDefaults.standard.string(forKey: "waveColor") ?? "dark"
        let barColor: NSColor = chosen == "green" ? .systemGreen
            : chosen == "red" ? .systemRed
            : .black.withAlphaComponent(0.78)
        (busy ? NSColor.black.withAlphaComponent(0.25) : barColor).setFill()
        for i in 0..<bars {
            let sway = busy ? 0.35 : heights[i]
            let h = max(3, maxH * sway)
            let r = NSRect(x: x0 + CGFloat(i) * (barW + gap),
                           y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

/// Короткая всплывашка с текстом — для случаев вроде «курсор был не в поле».
final class Toast {
    static let shared = Toast()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // тот же стиль, что у плашки с волной: белая, с тонкой окантовкой
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .black.withAlphaComponent(0.85)
        label.alignment = .center
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        box.layer?.cornerRadius = 13
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        box.addSubview(label)
        panel.contentView = box
    }

    func show(_ text: String, seconds: Double = 3.5) {
        label.stringValue = text
        label.sizeToFit()
        let pad: CGFloat = 12
        let size = NSSize(width: label.frame.width + pad * 2,
                          height: label.frame.height + pad)
        label.setFrameOrigin(NSPoint(x: pad, y: pad / 2))
        let p = NSEvent.mouseLocation
        var origin = NSPoint(x: p.x + 14, y: p.y - size.height - 12)
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }
}

final class WavePanel {
    private let panel: NSPanel
    private let view = WaveView()

    /// Куда пользователь перетащил плашку. Пока не таскал — nil,
    /// и плашка ходит за текстовой кареткой.
    static var pinned: NSPoint? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "wavePos") else { return nil }
            let parts = s.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
        }
        set {
            if let p = newValue {
                UserDefaults.standard.set("\(p.x),\(p.y)", forKey: "wavePos")
            } else {
                UserDefaults.standard.removeObject(forKey: "wavePos")
            }
        }
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 78, height: 26),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        // Перетаскивание (и только его!) ловит сама WaveView — см. mouseUp.
    }

    /// Место плашки для данного якоря: прибитое, если её перетаскивали,
    /// иначе чуть ниже и правее точки набора — и не за краем экрана.
    private func clampedOrigin(for p: NSPoint) -> NSPoint {
        let size = panel.frame.size
        var origin = Self.pinned ?? NSPoint(x: p.x + 14, y: p.y - size.height - 10)
        let anchor = Self.pinned ?? p
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        return origin
    }

    func show(near p: NSPoint) {
        let origin = clampedOrigin(for: p)
        view.busy = false
        NSLog("Гига волна: показ в \(origin)\(Self.pinned != nil ? " (прибита)" : "")")
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Во время записи: окно с кареткой переехало — плашка следом.
    /// Прибитую не трогаем; когда её тащат мышью — тем более.
    func follow(_ anchor: NSPoint?) {
        guard let anchor, Self.pinned == nil, panel.isVisible, !view.dragging else { return }
        let o = clampedOrigin(for: anchor)
        let cur = panel.frame.origin
        guard abs(o.x - cur.x) > 2 || abs(o.y - cur.y) > 2 else { return }
        panel.setFrameOrigin(o)
    }

    func tick() { view.tick() }

    func busy() {
        view.busy = true
        view.needsDisplay = true
    }

    func hide() { panel.orderOut(nil) }
}
