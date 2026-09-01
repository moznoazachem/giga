// Плашка с волной голоса рядом с местом набора текста.
//
// Волна в строке меню наверху видна плохо, когда экран большой и смотришь
// на курсор. Эта плашка появляется у текстовой каретки (спрашиваем через
// Accessibility, разрешение и так есть), а если каретку не отдали —
// у указателя мыши. Столбики показывают настоящую громкость с микрофона
// (среднеквадратичную, в децибелах): молчишь — лежат, говоришь — пляшут.
// Инерцию, из-за которой честная волна раньше выглядела вялой, снимает
// разная скорость вверх и вниз — см. tick(level:).

import AppKit

/// Где сейчас набирается текст. По убыванию точности:
/// каретка активного поля → низ самого поля → низ активного окна →
/// указатель мыши. На виртуальных машинах Accessibility часто молчит
/// и про каретку, и про поле — раньше плашка сваливалась к мыши,
/// которая лежит где попало, и «появлялась в разных концах экрана».
func typingAnchor() -> NSPoint {
    if let p = typingAnchorIfKnown(log: true) { return p }
    NSLog("Гига якорь: мышь \(NSEvent.mouseLocation)")
    return NSEvent.mouseLocation
}

/// Якорь без запасного варианта «мышь» — для слежения во время записи:
/// за окном с кареткой плашка ходить должна, а за мышью — нет.
func typingAnchorIfKnown(log: Bool = false) -> NSPoint? {
    let field = focusedFieldFrame()
    if let p = caretPoint() {
        // Каретка обязана лежать в своём поле. Точка вне поля — враньё
        // (виртуалки и терминалы любят так отвечать), не верим ей.
        if field == nil || field!.insetBy(dx: -40, dy: -40).contains(p) {
            if log { NSLog("Гига якорь: каретка \(p)") }
            return p
        }
        if log { NSLog("Гига якорь: каретка \(p) вне поля \(field!) — мусор") }
    }
    if let f = field {
        if log { NSLog("Гига якорь: поле \(f)") }
        return NSPoint(x: f.midX, y: f.minY + 30)
    }
    if let w = focusedWindowFrame() {
        if log { NSLog("Гига якорь: окно \(w)") }
        return NSPoint(x: w.midX, y: w.minY + 60)
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

/// Рамка активного окна — предпоследний якорь. Окно система знает
/// всегда, даже когда про каретку и поле отмалчивается (виртуалки).
func focusedWindowFrame() -> NSRect? {
    var appRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                        "AXFocusedApplication" as CFString,
                                        &appRef) == .success,
          let a = appRef, CFGetTypeID(a) == AXUIElementGetTypeID()
    else { return nil }
    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(a as! AXUIElement,
                                        "AXFocusedWindow" as CFString,
                                        &winRef) == .success,
          let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID()
    else { return nil }
    let win = w as! AXUIElement
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, "AXPosition" as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(win, "AXSize" as CFString, &sizeRef) == .success,
          let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID(),
          let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID()
    else { return nil }
    var pos = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos),
          AXValueGetValue(sv as! AXValue, .cgSize, &size),
          size.height > 0
    else { return nil }
    let out = axFlip(CGRect(origin: pos, size: size))
    guard axOnScreen(out) else { return nil }
    return out
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

    /// Сколько столбиков в плашке.
    static let bars = 13

    /// Высоты столбиков, 0…1. Наружу отданы затем, что этими же числами
    /// кормится иконка в строке меню: две волны об одном и том же звуке
    /// и обязаны идти в такт.
    private(set) var heights = [CGFloat](repeating: 0, count: WaveView.bars)

    /// Сглаженная громкость 0…1 — показываем её, а не сырую: сырая
    /// дёргается покадрово и читается как рябь.
    private var level: CGFloat = 0

    /// Своя доля громкости у каждого столбика и своё опоздание в кадрах.
    /// Перебрасываются РАЗ НА ВСПЛЕСК, а не каждый кадр: покадровый
    /// рандом читается как дрожь, а разовый — как живой голос, от
    /// которого столбики дёрнулись вразнобой и снова замерли.
    private var gain = [CGFloat](repeating: 1, count: WaveView.bars)
    private var lag = [Int](repeating: 0, count: WaveView.bars)

    /// Кадров с начала всплеска; nil — столбики просто стоят на громкости.
    private var burst: Int?

    /// Насколько громче должно стать, чтобы это считалось всплеском,
    /// и на сколько кадров столбики могут разъехаться внутри него
    /// (9 кадров — это 150 мс).
    private static let burstTrigger: CGFloat = 0.1
    private static let burstSpread = 9

    // Кадр — 1/60 секунды, и все доли ниже посчитаны под него. Если
    // менять частоту таймера в main.swift — пересчитывать и их:
    // доля за кадр = 1 − (1 − прежняя доля)^(прежняя частота / новая).
    private static let riseRate: CGFloat = 0.75      // подъём, ~30 мс до цели
    private static let fallRate: CGFloat = 0.13      // спад на тихой речи, ~120 мс
    private static let fallLoud: CGFloat = 0.45      // добавка к спаду на полной громкости

    /// Кадров с прошлой пересыпки — по нему громкий голос гонит
    /// столбики дальше, не дожидаясь нового всплеска.
    private var sinceRoll = 0

    /// Масштаб появления, 1 — плашка в полный рост. Рисуем от левого
    /// верхнего угла: там каретка, и плашка будто выпрыгивает из-под неё.
    var scale: CGFloat = 1

    /// С какой громкости плашка начинает частить.
    private static let livelyFrom: CGFloat = 0.35

    /// Горка: середина выше краёв, чтобы плашка читалась волной,
    /// а не забором. Считаем от места столбика в ряду.
    private static func shape(_ i: Int) -> CGFloat {
        0.72 + 0.28 * sin(CGFloat.pi * (CGFloat(i) + 0.5) / CGFloat(bars))
    }

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
        }
        dragMouse = nil; dragOrigin = nil; dragged = false
    }

    /// Кадр волны по свежей громкости с микрофона. Вверх — почти рывком
    /// (голос должен попадать в столбик в тот же кадр, иначе волна
    /// плетётся за речью), вниз — медленнее, иначе столбики рушатся
    /// в паузах между слогами и волна начинает мигать.
    /// Новая раскладка столбиков. Чем громче голос, тем шире разброс
    /// высот и тем теснее столбики по времени: на крике они должны
    /// разлетаться, на тихой речи — вести себя смирно.
    private func roll() {
        let низ = 0.75 - 0.55 * level
        let разброс = max(3, Self.burstSpread - Int(6 * level))
        for i in 0..<Self.bars {
            gain[i] = CGFloat.random(in: низ...1.0)
            lag[i] = Int.random(in: 0...разброс)
        }
        burst = 0
        sinceRoll = 0
    }

    func tick(level target: CGFloat) {
        let рост = target - level
        level += рост * (рост > 0 ? Self.riseRate : Self.fallRate)
        sinceRoll += 1

        // Голос прибавил — всплеск: каждый столбик берёт себе новую долю
        // громкости и новое опоздание. Пока прошлый всплеск не отыграл,
        // новый не начинаем, иначе доли перебрасывались бы каждый кадр
        // и вернулась бы дрожь.
        if рост > Self.burstTrigger, burst == nil {
            roll()
        } else if level > Self.livelyFrom, sinceRoll >= max(4, Int(18 - 15 * level)) {
            // А пока голос громкий, столбики пересыпаются и сами, без
            // нового всплеска: на полной громкости раз в 100 мс, у порога
            // — втрое реже. Честной громкости в этом уже нет, это
            // украшение: на крике плашка должна выглядеть так же бойко,
            // как звучит голос, а громкость к тому времени упёрлась
            // в потолок и сама по себе перестала что-либо показывать.
            roll()
        }

        for i in 0..<heights.count {
            // столбик, чья очередь ещё не подошла, стоит как стоял —
            // от этого всплеск и выглядит разнобоем, а не общим прыжком
            if let age = burst, age < lag[i] { continue }
            let свой = level * Self.shape(i) * gain[i]
            // Вверх столбик идёт всегда рывком, вниз — тем резче, чем
            // громче голос: на тихой речи оседает плавно, на громкой
            // рушится почти мгновенно. Отсюда и размах: на крике столбики
            // не покачиваются около одной высоты, а рушатся и взлетают.
            let скорость = свой > heights[i] ? Self.riseRate
                                             : Self.fallRate + Self.fallLoud * level
            heights[i] += (свой - heights[i]) * скорость
        }

        if let age = burst { burst = age < Self.burstSpread ? age + 1 : nil }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let растёт = scale != 1
        if растёт {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: 0, yBy: bounds.height) // якорь — левый верхний угол
            t.scaleX(by: scale, yBy: scale)
            t.translateX(by: 0, yBy: -bounds.height)
            t.concat()
        }
        defer { if растёт { NSGraphicsContext.restoreGraphicsState() } }

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
        // 13 столбиков: 2,5 пункта ширины с зазором 1,5, поля по краям
        // почти по девять. Шире ряд делать некуда — крайний столбик
        // полез бы за скруглённый торец плашки.
        let barW: CGFloat = 2.5
        let gap: CGFloat = 1.5
        let totalW = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
        let x0 = (bounds.width - totalW) / 2
        // Полей сверху и снизу — по пункту: столбик на всплеске должен
        // выстреливать во всю плашку, иначе размах пропадает даром.
        let maxH = bounds.height - 2

        // цвет столбиков выбирается в меню приложения
        let chosen = UserDefaults.standard.string(forKey: "waveColor") ?? "dark"
        let barColor: NSColor = chosen == "green" ? .systemGreen
            : chosen == "red" ? .systemRed
            : .black.withAlphaComponent(0.78)
        // Пока Писарь думает, плашка остаётся на месте и синеет: работа
        // не кончилась, текст сейчас появится — а серые столбики
        // выглядели так, будто волна умерла.
        (busy ? busyColor : barColor).setFill()
        // В покое столбик должен быть кружком, а не лежачим овалом:
        // нижний предел высоты равен ширине. Вертикальный овал —
        // это barW * 1.75.
        let restH = barW
        for i in 0..<bars {
            let sway = busy ? BUSY_BAR : heights[i]
            let h = max(restH, maxH * sway)
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

    private var generation = 0

    /// Липкая плашка-статус: висит, пока не позовут hide().
    func showSticky(_ text: String) { show(text, seconds: 0) }

    func hide() {
        generation += 1
        panel.orderOut(nil)
    }

    func show(_ text: String, seconds: Double = 3.5, near point: NSPoint? = nil) {
        label.stringValue = text
        label.sizeToFit()
        let pad: CGFloat = 12
        let size = NSSize(width: label.frame.width + pad * 2,
                          height: label.frame.height + pad)
        label.setFrameOrigin(NSPoint(x: pad, y: pad / 2))
        // якорь можно задать снаружи (например, под иконкой в строке меню);
        // иначе — у места набора: смотрят туда, где появится текст
        let p = point ?? typingAnchorIfKnown() ?? NSEvent.mouseLocation
        var origin = NSPoint(x: p.x + 14, y: p.y - size.height - 12)
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        generation += 1
        let g = generation
        if seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.generation == g else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}

final class WavePanel {
    private let panel: NSPanel
    private let view = WaveView()
    private var popTimer: Timer?

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
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 68, height: 26),
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
        pop()
    }

    /// Появление: плашка за 12 кадров вырастает из левого верхнего угла,
    /// в конце чуть перелетает свой размер и садится обратно. Само окно
    /// всё это время стоит на месте в полный рост — растёт только рисунок,
    /// поэтому ни положение, ни перетаскивание от анимации не зависят.
    private func pop() {
        popTimer?.invalidate()
        let кадров = 12
        var кадр = 0
        view.scale = Self.popFrom
        view.needsDisplay = true
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            кадр += 1
            if кадр >= кадров {
                self.view.scale = 1
                tm.invalidate()
                self.popTimer = nil
            } else {
                // easeOutBack: к концу перелетает размер примерно на 7%
                let x = CGFloat(кадр) / CGFloat(кадров) - 1
                let ход = 1 + (Self.popBack + 1) * x * x * x + Self.popBack * x * x
                self.view.scale = Self.popFrom + (1 - Self.popFrom) * ход
            }
            self.view.needsDisplay = true
            self.panel.invalidateShadow() // тень должна ужиматься вместе с плашкой
        }
        RunLoop.main.add(t, forMode: .common)
        popTimer = t
    }

    /// С какого размера начинается появление и насколько сильно
    /// плашка перелетает свой размер в конце.
    private static let popFrom: CGFloat = 0.35
    private static let popBack: CGFloat = 1.2

    /// Во время записи: окно с кареткой переехало — плашка следом.
    /// Прибитую не трогаем; когда её тащат мышью — тем более.
    func follow(_ anchor: NSPoint?) {
        guard let anchor, Self.pinned == nil, panel.isVisible, !view.dragging else { return }
        let o = clampedOrigin(for: anchor)
        let cur = panel.frame.origin
        guard abs(o.x - cur.x) > 2 || abs(o.y - cur.y) > 2 else { return }
        panel.setFrameOrigin(o)
    }

    func tick(level: CGFloat) { view.tick(level: level) }

    /// Столбики для иконки в строке меню: там места на пять, поэтому
    /// берём каждый третий — иконка живёт тем же звуком, что и плашка.
    var bars: [CGFloat] {
        let h = view.heights
        return (0..<5).map { h[$0 * (h.count - 1) / 4] }
    }

    func busy() {
        view.busy = true
        view.needsDisplay = true
    }

    func hide() {
        popTimer?.invalidate()
        popTimer = nil
        view.scale = 1
        panel.orderOut(nil)
    }
}
