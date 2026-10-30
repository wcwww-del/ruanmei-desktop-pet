import AppKit

enum PetMetrics {
    /// 宠物上下各留出的气泡空间（窗口本身是透明的，只有宠物和气泡接收鼠标）
    static let bubblePad: CGFloat = 136
    static let horizontalPad: CGFloat = 20
}

final class PetView: NSView {

    // MARK: 配置

    weak var controller: PetController?
    let effects: PetEffects
    private var image: NSImage { effects.pet }
    var petSize: CGFloat = 230 {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    // MARK: 动画状态

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var time: CGFloat = 0

    private var blinkStart: CGFloat = -10
    private var blinkDuration: CGFloat = 0.20
    private var nextBlinkAt: CGFloat = 2.6
    private var pendingDoubleBlink = false
    var debugScene: String?

    private var hop = Spring()
    private var tilt = Spring()
    private var squash = Spring()
    private var hoverLift = Spring()
    private var bubbleScale = Spring()
    private var bubbleAlpha = Spring()

    private var particles: [PetParticle] = []
    private var nextPetalAt: CGFloat = 0.8
    private var nextSparkleAt: CGFloat = 3.0

    /// 梅花飘落开关。关闭时立刻清掉还在飘的花瓣，打开后很快重新飘起来。
    var petalsEnabled = true {
        didSet {
            guard petalsEnabled != oldValue else { return }
            if petalsEnabled {
                nextPetalAt = time + 0.5
            } else {
                particles.removeAll { $0.kind == .petal }
                needsDisplay = true
            }
        }
    }

    // MARK: 气泡

    private struct Bubble {
        let text: String
        let attributed: NSAttributedString
        let textSize: CGSize
        let shownAt: CGFloat
        let duration: CGFloat
    }

    private var bubble: Bubble?
    private var bubbleDismissing = false
    private var bubbleHitRect: CGRect = .zero

    // MARK: 交互

    private var hovering = false
    private var dragging = false
    private var pressScreen = NSPoint.zero
    private var pressOrigin = NSPoint.zero
    private var lastDragScreen = NSPoint.zero
    private var lastDragTime: CFTimeInterval = 0
    private var dragVX: CGFloat = 0
    private var dragVY: CGFloat = 0
    private var cursorLocal = NSPoint.zero
    private var lastClickTime: CFTimeInterval = 0
    private var clickCount = 0

    var isDragging: Bool { dragging }

    // MARK: 初始化

    init(effects: PetEffects) {
        self.effects = effects
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
        startTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: 几何

    var petRect: CGRect {
        let s = petSize
        return CGRect(x: (bounds.width - s) / 2,
                      y: (bounds.height - s) / 2,
                      width: s, height: s)
    }

    /// 只有宠物本体和气泡响应鼠标，其余透明区域让点击穿透到桌面。
    func acceptsPoint(_ point: CGPoint) -> Bool {
        if bubbleHitRect != .zero && bubbleHitRect.insetBy(dx: -4, dy: -4).contains(point) {
            return true
        }
        let r = petRect
        guard r.insetBy(dx: -4, dy: -4).contains(point) else { return false }
        let nx = (point.x - r.midX) / (r.width * 0.47)
        let ny = (point.y - r.midY) / (r.height * 0.48)
        return nx * nx + ny * ny <= 1.0
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsPoint(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(petRect, cursor: .openHand)
    }

    // MARK: - 对外动作

    func showBubble(_ text: String, duration: CGFloat = 5.5) {
        let font = NSFont(name: "PingFangSC-Medium", size: 14.5)
            ?? NSFont.systemFont(ofSize: 14.5, weight: .medium)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = .left
        style.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Palette.ink,
            .paragraphStyle: style
        ]
        let maxTextWidth: CGFloat = 214
        let size = (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).size
        let attributed = NSAttributedString(string: text, attributes: attrs)
        bubble = Bubble(text: text,
                        attributed: attributed,
                        textSize: CGSize(width: ceil(size.width), height: ceil(size.height)),
                        shownAt: time,
                        duration: duration)
        bubbleDismissing = false
        bubbleScale.reset(0.72)
        bubbleScale.target = 1
        bubbleAlpha.reset(0)
        bubbleAlpha.target = 1
        needsDisplay = true
    }

    func dismissBubble() {
        guard bubble != nil else { return }
        bubbleDismissing = true
        bubbleAlpha.target = 0
        bubbleScale.target = 0.92
    }

    func celebrate(double: Bool) {
        hop.kick(double ? 360 : 250)
        tilt.kick(double ? 38 : 16)
        squash.kick(double ? 1.4 : 0.8)
        emitHearts(count: double ? 10 : 6)
        if blinkStart < 0 { startBlink() }
    }

    func happyHop() {
        hop.kick(220)
        tilt.kick(12)
        if blinkStart < 0 { startBlink() }
    }

    func waterReminder() {
        // 与 assets/ruanmei_voice.m4a 的语音内容保持一致
        showBubble("休息一下，茶点时间到了。", duration: 9)
        hop.kick(260)
        tilt.kick(-14)
        emitDroplets()
        emitSparkles(count: 7)
        if blinkStart < 0 { startBlink() }
    }

    func setHovering(_ inside: Bool, cursor: CGPoint) {
        hovering = inside
        cursorLocal = cursor
    }

    func petDidBeginDrag() {
        dragging = true
        hoverLift.target = 1
        NSCursor.closedHand.set()
    }

    func petDidEndDrag() {
        dragging = false
        dragVX = 0
        dragVY = 0
        tilt.target = 0
        squash.target = 0
        hop.kick(110)
        NSCursor.openHand.set()
    }

    // MARK: - 主循环

    private func tick() {
        let now = CACurrentMediaTime()
        var dt = CGFloat(now - lastTick)
        lastTick = now
        if dt < 0 { dt = 0 }
        dt = clamp(dt, 0, 0.05)
        time += dt

        updateBlink()

        // 弹簧目标
        hoverLift.target = (hovering && !dragging) ? 1 : 0
        if dragging {
            tilt.target = clamp(-dragVX * 0.012, -13, 13)
            squash.target = clamp(abs(dragVX) * 0.000055, 0, 0.075)
        } else {
            let lean = ((cursorLocal.x - petRect.midX) / max(1, petRect.width)) * 3.2
            tilt.target = hovering ? clamp(-lean, -4, 4) : sin(time * 0.75) * 1.25
            squash.target = 0
        }

        hop.step(dt, stiffness: 95, damping: 8.5)
        tilt.step(dt, stiffness: 130, damping: 14)
        squash.step(dt, stiffness: 150, damping: 18)
        hoverLift.step(dt, stiffness: 140, damping: 20)
        bubbleScale.step(dt, stiffness: 320, damping: 24)
        bubbleAlpha.step(dt, stiffness: 260, damping: 28)

        if let b = bubble, time > b.shownAt + b.duration, !bubbleDismissing {
            dismissBubble()
        }
        if bubbleDismissing && bubbleAlpha.value < 0.03 {
            bubble = nil
            bubbleDismissing = false
            bubbleHitRect = .zero
        }

        // 花瓣
        if petalsEnabled && time > nextPetalAt {
            spawnPetal()
            nextPetalAt = time + CGFloat.random(in: 0.75...1.9)
        }
        if time > nextSparkleAt {
            emitSparkles(count: 1)
            nextSparkleAt = time + CGFloat.random(in: 2.6...5.4)
        }

        var i = 0
        while i < particles.count {
            particles[i].step(dt)
            if particles[i].life <= 0 {
                particles.remove(at: i)
            } else {
                i += 1
            }
        }

        if !bubbleDismissing, bubble != nil {
            bubbleScale.target = 1
            bubbleAlpha.target = 1
        }

        needsDisplay = true
    }

    // MARK: 眨眼

    private func updateBlink() {
        if blinkStart < 0 && time > nextBlinkAt {
            startBlink()
            nextBlinkAt = time + CGFloat.random(in: 3.0...6.8)
            return
        }
        if blinkStart >= 0 && time - blinkStart > blinkDuration {
            blinkStart = -1
            if pendingDoubleBlink {
                pendingDoubleBlink = false
                nextBlinkAt = time + 0.16
            } else {
                nextBlinkAt = time + CGFloat.random(in: 3.0...6.8)
            }
        }
    }

    private func startBlink() {
        blinkStart = time
        blinkDuration = 0.20
        pendingDoubleBlink = Double.random(in: 0..<1) < 0.18
    }

    private func currentBlinkImage() -> (NSImage, CGFloat)? {
        guard let half = effects.blinkHalf, let closed = effects.blinkClosed else { return nil }
        if debugScene == "blink" { return (closed, 1) }
        guard blinkStart >= 0 else { return nil }
        let p = (time - blinkStart) / blinkDuration
        if p < 0 || p > 1 { return nil }
        if p < 0.35 { return (half, p / 0.35) }
        if p > 0.72 { return (half, (1 - p) / 0.28) }
        return (closed, 1)
    }

    // MARK: - 粒子生成

    private func spawnPetal() {
        let x = CGFloat.random(in: 20...max(21, bounds.width - 20))
        let size = CGFloat.random(in: 7...13)
        let behind = Bool.random()
        var p = PetParticle(
            kind: .petal,
            position: CGPoint(x: x, y: bounds.height - 8),
            velocity: CGVector(dx: CGFloat.random(in: -10...10), dy: CGFloat.random(in: -52...(-26))),
            life: CGFloat.random(in: 7...11),
            maxLife: 11,
            size: size,
            angle: CGFloat.random(in: 0...(2 * .pi)),
            spin: CGFloat.random(in: -0.9...0.9),
            gravity: 2.2,
            drag: 0.55,
            color: Palette.petal.withAlphaComponent(CGFloat.random(in: 0.55...0.9)),
            seed: CGFloat.random(in: 0...10),
            behind: behind
        )
        p.maxLife = p.life
        particles.append(p)
    }

    private func emitHearts(count: Int) {
        let c = CGPoint(x: petRect.midX, y: petRect.minY + petRect.height * 0.28)
        for _ in 0..<count {
            let life = CGFloat.random(in: 1.3...2.1)
            let p = PetParticle(
                kind: .heart,
                position: CGPoint(x: c.x + CGFloat.random(in: -46...46), y: c.y + CGFloat.random(in: -10...40)),
                velocity: CGVector(dx: CGFloat.random(in: -26...26), dy: CGFloat.random(in: 55...120)),
                life: life, maxLife: life,
                size: CGFloat.random(in: 9...16),
                angle: CGFloat.random(in: -0.3...0.3),
                spin: CGFloat.random(in: -1.2...1.2),
                gravity: 95,
                drag: 0.4,
                color: NSColor(srgbRed: 0.94, green: 0.45, blue: 0.58, alpha: CGFloat.random(in: 0.65...0.95)),
                seed: 0
            )
            particles.append(p)
        }
    }

    private func emitDroplets() {
        let c = CGPoint(x: petRect.midX, y: petRect.minY + petRect.height * 0.3)
        for _ in 0..<18 {
            let life = CGFloat.random(in: 1.0...1.8)
            let p = PetParticle(
                kind: .droplet,
                position: CGPoint(x: c.x + CGFloat.random(in: -70...70), y: c.y + CGFloat.random(in: -20...60)),
                velocity: CGVector(dx: CGFloat.random(in: -70...70), dy: CGFloat.random(in: 80...200)),
                life: life, maxLife: life,
                size: CGFloat.random(in: 6...12),
                angle: CGFloat.random(in: -0.4...0.4),
                spin: CGFloat.random(in: -0.8...0.8),
                gravity: 260,
                drag: 0.15,
                color: Palette.water.withAlphaComponent(CGFloat.random(in: 0.6...0.95)),
                seed: 0
            )
            particles.append(p)
        }
    }

    private func emitSparkles(count: Int) {
        for _ in 0..<count {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let radius = petSize * CGFloat.random(in: 0.34...0.5)
            let life = CGFloat.random(in: 0.9...1.8)
            let p = PetParticle(
                kind: .sparkle,
                position: CGPoint(x: petRect.midX + cos(angle) * radius,
                                  y: petRect.midY + sin(angle) * radius),
                velocity: CGVector(dx: CGFloat.random(in: -8...8), dy: CGFloat.random(in: 10...35)),
                life: life, maxLife: life,
                size: CGFloat.random(in: 5...12),
                angle: 0, spin: 0.6,
                gravity: -4, drag: 0.8,
                color: Palette.mint.withAlphaComponent(0.9),
                seed: 0
            )
            particles.append(p)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        let r = petRect
        let cx = r.midX

        // 呼吸/浮动
        let breath = sin(time * 1.75 - 0.5)
        let bob = sin(time * 1.75) * 3.6 + hoverLift.value * 3.0
        let scaleY = (1 + breath * 0.012) * (1 + squash.value * 0.55)
        let scaleX = (1 - breath * 0.008) * (1 - squash.value * 0.55)
        let baseY = r.minY + 4 + bob + hop.value
        let angle = tilt.value * .pi / 180

        drawAura(ctx, center: CGPoint(x: cx, y: r.midY + 8 + bob * 0.6))
        drawShadow(ctx, rect: r, baseY: baseY, angle: angle)
        drawParticles(ctx, behind: true)

        ctx.saveGState()
        ctx.translateBy(x: cx, y: baseY)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: scaleX, y: scaleY)
        let aspect = image.size.width / max(1, image.size.height)
        var drawW = r.width
        var drawH = r.height
        if aspect > 1 {
            drawH = r.width / aspect
        } else if aspect < 1 {
            drawW = r.height * aspect
        }
        let drawRect = CGRect(x: -drawW / 2, y: 0, width: drawW, height: drawH)
        image.draw(in: drawRect,
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1,
                   respectFlipped: false,
                   hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high])

        if let (overlay, alpha) = currentBlinkImage() {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            overlay.draw(in: drawRect,
                         from: .zero,
                         operation: .sourceOver,
                         fraction: 1,
                         respectFlipped: false,
                         hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high])
            ctx.restoreGState()
        }
        ctx.restoreGState()

        drawParticles(ctx, behind: false)
        drawBubble(ctx)
    }

    private func drawShadow(_ ctx: CGContext, rect: CGRect, baseY: CGFloat, angle: CGFloat) {
        guard let shadow = effects.shadow else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: baseY - rect.height * 0.015)
        ctx.rotate(by: angle)
        ctx.setAlpha(0.55)
        shadow.draw(in: CGRect(x: -rect.width / 2, y: 0, width: rect.width, height: rect.height),
                    from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: false,
                    hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high])
        ctx.restoreGState()
    }

    private func drawAura(_ ctx: CGContext, center: CGPoint) {
        let pulse = 1 + sin(time * 1.15) * 0.05
        let colors = [Palette.mint.withAlphaComponent(0.14).cgColor,
                      Palette.mint.withAlphaComponent(0.0).cgColor] as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors,
                                    locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1.0, y: 0.92)
        ctx.drawRadialGradient(grad,
                               startCenter: .zero, startRadius: petSize * 0.16,
                               endCenter: .zero, endRadius: petSize * 0.60 * pulse,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private func drawParticles(_ ctx: CGContext, behind: Bool) {
        for p in particles where p.behind == behind {
            let progress = 1 - max(0, p.life / max(0.001, p.maxLife))
            var alpha: CGFloat = 1
            if p.kind == .petal {
                alpha = min(1, p.life / 1.5) * min(1, progress * 6)
            } else {
                alpha = min(1, p.life / 0.35)
            }
            guard alpha > 0.01 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: p.position.x, y: p.position.y)
            ctx.rotate(by: p.angle)
            ctx.setAlpha(alpha)
            switch p.kind {
            case .petal:
                let path = Paths.blossom(center: .zero, radius: p.size, rotation: 0)
                p.color.setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.25).setStroke()
                path.lineWidth = 0.6
                path.stroke()
            case .heart:
                let rect = CGRect(x: -p.size / 2, y: -p.size / 2,
                                  width: p.size, height: p.size)
                p.color.setFill()
                Paths.heart(in: rect).fill()
            case .droplet:
                let rect = CGRect(x: -p.size * 0.36, y: -p.size * 0.5,
                                  width: p.size * 0.72, height: p.size)
                let path = Paths.droplet(in: rect)
                p.color.setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.55).setFill()
                ctx.fillEllipse(in: CGRect(x: -p.size * 0.16, y: -p.size * 0.16,
                                           width: p.size * 0.15, height: p.size * 0.15))
            case .sparkle:
                let rect = CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size)
                p.color.setFill()
                Paths.sparkle(in: rect).fill()
            }
            ctx.restoreGState()
        }
    }

    // MARK: 气泡

    private func bubbleMetrics() -> (rect: CGRect, above: Bool, tailX: CGFloat)? {
        guard let b = bubble else { return nil }
        let width = min(300, max(150, b.textSize.width + 56))
        let height = max(50, b.textSize.height + 22)
        let r = petRect

        let screenRect = window?.convertToScreen(convert(r, to: nil)) ?? r
        let petTop = screenRect.maxY
        let petBottom = screenRect.minY
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let roomAbove = visible.maxY - petTop
        let roomBelow = petBottom - visible.minY
        var above = true
        if roomAbove < height + 16 && roomBelow > roomAbove { above = false }

        var x = r.midX - width / 2
        x = clamp(x, 8, max(8, bounds.width - width - 8))
        let y = above ? r.maxY + 10 : r.minY - height - 10
        return (CGRect(x: x, y: y, width: width, height: height), above, clamp(r.midX, x + 20, x + width - 20))
    }

    private func drawBubble(_ ctx: CGContext) {
        guard let b = bubble, let m = bubbleMetrics() else {
            bubbleHitRect = .zero
            return
        }
        let alpha = bubbleAlpha.value
        guard alpha > 0.01 else {
            bubbleHitRect = .zero
            return
        }
        let rect = m.rect
        bubbleHitRect = rect.insetBy(dx: -2, dy: -2)

        ctx.saveGState()
        ctx.setAlpha(alpha)
        let anchor = CGPoint(x: m.tailX, y: m.above ? rect.minY + 2 : rect.maxY - 2)
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.scaleBy(x: bubbleScale.value, y: bubbleScale.value)
        ctx.translateBy(x: -anchor.x, y: -anchor.y)

        let body = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        let tail = NSBezierPath()
        if m.above {
            tail.move(to: CGPoint(x: m.tailX - 8, y: rect.minY + 1))
            tail.line(to: CGPoint(x: m.tailX + 8, y: rect.minY + 1))
            tail.line(to: CGPoint(x: m.tailX, y: rect.minY - 8))
        } else {
            tail.move(to: CGPoint(x: m.tailX - 8, y: rect.maxY - 1))
            tail.line(to: CGPoint(x: m.tailX + 8, y: rect.maxY - 1))
            tail.line(to: CGPoint(x: m.tailX, y: rect.maxY + 8))
        }
        tail.close()
        body.append(tail)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14,
                      color: NSColor.black.withAlphaComponent(0.22).cgColor)
        NSColor(srgbRed: 0.995, green: 0.992, blue: 0.975, alpha: 0.97).setFill()
        body.fill()
        ctx.restoreGState()

        NSColor.white.withAlphaComponent(0.85).setStroke()
        body.lineWidth = 0.8
        body.stroke()

        // 水滴图标
        let iconRect = CGRect(x: rect.minX + 14, y: rect.midY - 11, width: 18, height: 22)
        let drop = Paths.droplet(in: iconRect)
        let grad = NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.86, blue: 0.97, alpha: 1),
                                       Palette.waterDeep])!
        grad.draw(in: drop, angle: -90)
        NSColor.white.withAlphaComponent(0.55).setFill()
        ctx.fillEllipse(in: CGRect(x: iconRect.minX + 5, y: iconRect.midY - 2, width: 3.2, height: 4.6))

        // 文案
        let textRect = CGRect(x: iconRect.maxX + 10,
                              y: rect.midY - b.textSize.height / 2,
                              width: rect.width - (iconRect.maxX + 10 - rect.minX) - 12,
                              height: b.textSize.height + 2)
        b.attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])

        ctx.restoreGState()

        if alpha < 0.2 { bubbleHitRect = .zero }
    }

    // MARK: - 拖拽

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bubbleHitRect.insetBy(dx: -6, dy: -6).contains(p) {
            dismissBubble()
            return
        }
        guard acceptsPoint(p) else { return }
        pressScreen = NSEvent.mouseLocation
        pressOrigin = window?.frame.origin ?? .zero
        lastDragScreen = pressScreen
        lastDragTime = CACurrentMediaTime()
        dragVX = 0
        dragVY = 0
        dragging = false
        window?.ignoresMouseEvents = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let loc = NSEvent.mouseLocation
        let dx = loc.x - pressScreen.x
        let dy = loc.y - pressScreen.y
        if !dragging && hypot(dx, dy) > 4 {
            dragging = true
            controller?.petDidBeginDrag()
            petDidBeginDrag()
        }
        guard dragging else { return }
        win.setFrameOrigin(NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))

        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, now - lastDragTime)
        let vx = (loc.x - lastDragScreen.x) / CGFloat(dt)
        let vy = (loc.y - lastDragScreen.y) / CGFloat(dt)
        dragVX = dragVX * 0.55 + vx * 0.45
        dragVY = dragVY * 0.55 + vy * 0.45
        lastDragScreen = loc
        lastDragTime = now
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            petDidEndDrag()
            controller?.petDidEndDrag()
        } else if acceptsPoint(convert(event.locationInWindow, from: nil)) {
            let now = CACurrentMediaTime()
            let interval = now - lastClickTime
            if interval > 1.0 {
                clickCount = 1
            } else {
                clickCount = min(4, clickCount + 1)
            }
            lastClickTime = now
            celebrate(double: clickCount >= 2)
            controller?.petClicked(count: clickCount)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(at: event)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }
}
