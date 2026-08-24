// Плашка с волной голоса рядом с местом набора текста.
//
// Волна в строке меню наверху видна плохо, когда экран большой и смотришь
// на курсор. Эта плашка появляется у текстовой каретки (спрашиваем через
// Accessibility, разрешение и так есть), а если каретку не отдали —
// у указателя мыши. Анимация виртуальная, в стиле эквалайзера: она говорит
// «идёт запись», а не показывает громкость — честная громкость выглядела
// вялой из-за инерции измерителя Apple.

import AppKit

/// Где сейчас набирается текст: каретка активного поля, иначе — мышь.
func typingAnchor() -> NSPoint {
    if let r = caretRect() { return NSPoint(x: r.midX, y: r.minY) }
    return NSEvent.mouseLocation
}

/// Прямоугольник текстовой каретки в кокоа-координатах, если приложение
/// её отдаёт. Многие (особенно на Electron) не отдают — тогда nil.
private func caretRect() -> NSRect? {
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                        "AXFocusedUIElement" as CFString,
                                        &focusedRef) == .success,
          let f = focusedRef, CFGetTypeID(f) == AXUIElementGetTypeID()
    else { return nil }
    let element = f as! AXUIElement

    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString,
                                        &rangeRef) == .success,
          let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID()
    else { return nil }

    var boundsRef: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        element, "AXBoundsForRange" as CFString, rr, &boundsRef) == .success,
          let br = boundsRef, CFGetTypeID(br) == AXValueGetTypeID()
    else { return nil }

    var rect = CGRect.zero
    guard AXValueGetValue(br as! AXValue, .cgRect, &rect), rect != .zero else { return nil }

    // AX отдаёт координаты от левого ВЕРХНЕГО угла главного экрана,
    // кокоа считает от левого нижнего — переворачиваем.
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height,
                  width: rect.width, height: rect.height)
}

final class WaveView: NSView {
    var busy = false
    private var heights: [CGFloat] = [0.4, 0.6, 0.8, 0.6, 0.4]

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

final class WavePanel {
    private let panel: NSPanel
    private let view = WaveView()
    private var movingProgrammatically = false

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

        // Плашку можно перетащить — тогда она запоминает место и больше
        // не бегает за кареткой (вернуть — пункт в меню приложения).
        panel.isMovableByWindowBackground = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.movingProgrammatically else { return }
            Self.pinned = self.panel.frame.origin
            // в меню появляется пункт «Вернуть волну к курсору»
            (NSApp.delegate as? App)?.buildMenu()
        }
    }

    /// Показывает плашку: на прибитом месте, если её перетаскивали,
    /// иначе возле точки набора — и в любом случае не за краем экрана.
    func show(near p: NSPoint) {
        let size = panel.frame.size
        var origin = Self.pinned ?? NSPoint(x: p.x + 14, y: p.y - size.height - 10)
        let anchor = Self.pinned ?? p
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        view.busy = false
        movingProgrammatically = true
        panel.setFrameOrigin(origin)
        movingProgrammatically = false
        panel.orderFrontRegardless()
    }

    func tick() { view.tick() }

    func busy() {
        view.busy = true
        view.needsDisplay = true
    }

    func hide() { panel.orderOut(nil) }
}
