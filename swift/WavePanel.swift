// Плашка с волной голоса рядом с местом набора текста.
//
// Волна в строке меню наверху видна плохо, когда экран большой и смотришь
// на курсор. Эта плашка появляется у текстовой каретки (спрашиваем через
// Accessibility, разрешение и так есть), а если каретку не отдали —
// у указателя мыши. Столбики пляшут от настоящей громкости голоса.

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
    var level: Float = 0
    var busy = false
    private var phase = 0.0

    func tick(level newLevel: Float) {
        level = newLevel
        phase += 0.45
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).addClip()
        NSColor.black.withAlphaComponent(0.72).setFill()
        bounds.fill()

        let bars = 5
        let mult: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
        let barW: CGFloat = 4
        let gap: CGFloat = 4
        let totalW = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
        let x0 = (bounds.width - totalW) / 2
        let maxH = bounds.height - 10

        (busy ? NSColor.systemGray : NSColor.systemRed).setFill()
        for i in 0..<bars {
            let sway = busy ? 0.35 : 0.15 + 0.85 * CGFloat(level)
                * (0.65 + 0.35 * CGFloat(sin(phase + Double(i) * 1.1)))
            let h = max(3, maxH * mult[i] * sway)
            let r = NSRect(x: x0 + CGFloat(i) * (barW + gap),
                           y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

final class WavePanel {
    private let panel: NSPanel
    private let view = WaveView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 78, height: 26),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
    }

    /// Показывает плашку возле точки, не вылезая за край экрана.
    func show(near p: NSPoint) {
        let size = panel.frame.size
        var origin = NSPoint(x: p.x + 14, y: p.y - size.height - 10)
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        view.busy = false
        view.level = 0
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func update(level: Float) { view.tick(level: level) }

    func busy() {
        view.busy = true
        view.needsDisplay = true
    }

    func hide() { panel.orderOut(nil) }
}
