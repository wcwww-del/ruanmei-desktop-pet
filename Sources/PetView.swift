import AppKit
import QuartzCore

enum PetMetrics {
    /// 宠物上下各留出的气泡空间（窗口本身是透明的，只有宠物和气泡接收鼠标）
    static let bubblePad: CGFloat = 136
    static let horizontalPad: CGFloat = 20
}

/// 桌宠画面全部由 Core Animation 图层合成。
///
/// 改造前的实现每 1/60 秒重绘一次整块视图（渐变、900×900 原图缩放、每帧重建贝塞尔路径），
/// 空闲时也要吃掉约 1/4 个 CPU 核。现在：
/// - 形象、投影、光环、眼睛、花瓣、气泡都在启动 / 换尺寸时烘焙成位图，只画一次；
/// - 呼吸、浮动、摇摆、光环脉动是无限循环的 CA 动画，交给渲染服务器；
/// - 眨眼、飘花、星光都是单次定时器，没有 60fps 主循环，空闲时主线程完全休眠。
final class PetView: NSView {

    // MARK: - 对外配置

    weak var controller: PetController?
    let effects: PetEffects

    var petSize: CGFloat = 230 {
        didSet {
            guard abs(petSize - oldValue) > 0.01 else { return }
            rebuildScene()
        }
    }

    /// 梅花飘落开关。关闭后立即清掉还在飘的花瓣，打开后约半秒重新飘起来。
    var petalsEnabled = true {
        didSet {
            guard petalsEnabled != oldValue else { return }
            if !petalsEnabled { clearPetals() }
            scheduleNextPetal()
        }
    }

    /// 低耗电模式：停掉呼吸、摇摆和粒子，只留静帧与眨眼。
    var lowPower = false {
        didSet {
            guard lowPower != oldValue else { return }
            applyIdleAnimations()
            scheduleNextPetal()
            scheduleNextSparkle()
        }
    }

    var debugScene: String?
    var isDragging: Bool { dragging }

    // MARK: - 图层

    private let auraGroup = CALayer()
    private let auraLayer = CALayer()
    private let petalBack = CALayer()
    private let bodyGroup = CALayer()
    private let hoverLayer = CALayer()
    private let hopLayer = CALayer()
    private let bobLayer = CALayer()
    private let breathLayer = CALayer()
    private let swayLayer = CALayer()
    private let tiltLayer = CALayer()
    private let squashLayer = CALayer()
    private let petLayer = CALayer()
    private let blinkHalfLayer = CALayer()
    private let blinkClosedLayer = CALayer()
    private let petalFront = CALayer()
    private let bubbleLayer = CALayer()

    private var sprites: PetImages.Sprites?
    private var spriteKey: String?

    // MARK: - 定时器（全部单次触发）

    private var blinkTimer: Timer?
    private var petalTimer: Timer?
    private var sparkleTimer: Timer?
    private var bubbleTimer: Timer?
    private var isPaused = false

    // MARK: - 气泡

    private struct BubbleState {
        let text: String
        let attributed: NSAttributedString
        let textSize: CGSize
        var above: Bool
        var rect: CGRect
        var sprite: PetImages.BubbleSprite?
        var dismissing: Bool
    }

    private var bubble: BubbleState?
    private var bubbleHitRect: CGRect = .zero

    // MARK: - 交互状态

    private var hovering = false
    private var dragging = false
    private var pressScreen = NSPoint.zero
    private var pressOrigin = NSPoint.zero
    private var lastDragScreen = NSPoint.zero
    private var lastDragTime: CFTimeInterval = 0
    private var dragVX: CGFloat = 0
    private var dragVY: CGFloat = 0
    private var lastLean: CGFloat = .nan
    private var lastClickTime: CFTimeInterval = 0
    private var clickCount = 0
    private var trackingAreaRef: NSTrackingArea?

    // MARK: - 初始化

    init(effects: PetEffects) {
        self.effects = effects
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        blinkTimer?.invalidate()
        petalTimer?.invalidate()
        sparkleTimer?.invalidate()
        bubbleTimer?.invalidate()
    }

    override var isOpaque: Bool { false }

    private func configureLayers() {
        guard let root = layer else { return }
        root.masksToBounds = false
        root.backgroundColor = NSColor.clear.cgColor

        for leaf in [auraLayer, petLayer, blinkHalfLayer, blinkClosedLayer, bubbleLayer] {
            leaf.contentsGravity = .resize
            leaf.masksToBounds = false
        }
        blinkHalfLayer.opacity = 0
        blinkClosedLayer.opacity = 0
        bubbleLayer.opacity = 0

        for container in [petalBack, petalFront] {
            container.masksToBounds = false
            container.anchorPoint = .zero
            container.position = .zero
        }

        root.addSublayer(auraGroup)
        auraGroup.addSublayer(auraLayer)
        root.addSublayer(petalBack)
        root.addSublayer(bodyGroup)
        root.addSublayer(petalFront)
        root.addSublayer(bubbleLayer)

        bodyGroup.addSublayer(hoverLayer)
        hoverLayer.addSublayer(hopLayer)
        hopLayer.addSublayer(bobLayer)
        bobLayer.addSublayer(breathLayer)
        breathLayer.addSublayer(swayLayer)
        swayLayer.addSublayer(tiltLayer)
        tiltLayer.addSublayer(squashLayer)
        squashLayer.addSublayer(petLayer)
        petLayer.addSublayer(blinkHalfLayer)
        petLayer.addSublayer(blinkClosedLayer)
    }

    // MARK: - 生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stopScheduledTimers()
            return
        }
        rebuildScene()
        scheduleNextBlink()
        scheduleNextPetal()
        scheduleNextSparkle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildScene()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard layer != nil else { return }
        relayout()
        if bubble != nil { updateBubbleLayout(appear: false) }
    }

    private var pixelScale: CGFloat {
        window?.backingScaleFactor ?? 2
    }

    /// 尺寸 / 屏幕缩放变化后重建全部位图与几何。
    private func rebuildScene() {
        guard layer != nil else { return }
        relayout()
        bakeImages()
        applyIdleAnimations()
        if bubble != nil { updateBubbleLayout(appear: false) }
    }

    private func relayout() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        root.frame = bounds
        petalBack.frame = bounds
        petalFront.frame = bounds

        let r = petRect
        bodyGroup.anchorPoint = .zero
        bodyGroup.bounds = CGRect(x: 0, y: 0, width: petSize, height: petSize)
        bodyGroup.position = CGPoint(x: r.minX, y: r.minY + 4)

        for chain in [hoverLayer, hopLayer, bobLayer, breathLayer, swayLayer, tiltLayer, squashLayer] {
            chain.masksToBounds = false
            chain.anchorPoint = CGPoint(x: 0.5, y: 0)
            chain.bounds = CGRect(x: 0, y: 0, width: petSize, height: petSize)
            chain.position = CGPoint(x: petSize / 2, y: 0)
        }
        for leaf in [petLayer, blinkHalfLayer, blinkClosedLayer] {
            leaf.anchorPoint = .zero
            leaf.bounds = CGRect(x: 0, y: 0, width: petSize, height: petSize)
            leaf.position = .zero
        }

        let auraSide = petSize * 1.2
        auraGroup.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        auraGroup.bounds = CGRect(x: 0, y: 0, width: auraSide, height: auraSide)
        auraGroup.position = CGPoint(x: r.midX, y: r.midY + 8)
        auraLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        auraLayer.bounds = auraGroup.bounds
        auraLayer.position = CGPoint(x: auraSide / 2, y: auraSide / 2)
    }

    private func bakeImages() {
        let scale = pixelScale
        let key = "\(Int(petSize.rounded()))-\(Int((scale * 100).rounded()))"
        guard key != spriteKey else { return }
        guard let baked = PetImages.sprites(for: effects, petSize: petSize, scale: scale) else { return }
        sprites = baked
        spriteKey = key

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for leaf in [auraLayer, petLayer, blinkHalfLayer, blinkClosedLayer, bubbleLayer] {
            leaf.contentsScale = scale
        }
        petLayer.contents = baked.card
        blinkHalfLayer.contents = baked.blinkHalf
        blinkClosedLayer.contents = baked.blinkClosed
        auraLayer.contents = baked.aura
        if debugScene == "blink" { blinkClosedLayer.opacity = 1 }
        CATransaction.commit()
    }

    // MARK: - 几何

    var petRect: CGRect {
        let side = petSize
        return CGRect(x: (bounds.width - side) / 2,
                      y: (bounds.height - side) / 2,
                      width: side, height: side)
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    // MARK: - 空闲动画（GPU 合成，无主线程参与）

    private func applyIdleAnimations() {
        let keys: [(CALayer, String)] = [(bobLayer, "idle.bob"),
                                         (breathLayer, "idle.breath"),
                                         (swayLayer, "idle.sway"),
                                         (auraLayer, "idle.aura.scale"),
                                         (auraGroup, "idle.aura.bob")]
        for (target, key) in keys { target.removeAnimation(forKey: key) }
        guard !lowPower, window != nil else {
            bobLayer.position.y = 0
            auraGroup.position.y = petRect.midY + 8
            return
        }

        let samples = 17
        func wave(_ index: Int, phase: Double = 0) -> CGFloat {
            CGFloat(sin(2 * .pi * Double(index) / Double(samples - 1) + phase))
        }
        let breathPeriod = 2 * Double.pi / 1.75

        // 上下浮动
        let bob = CAKeyframeAnimation(keyPath: "position.y")
        bob.values = (0..<samples).map { 3.6 * wave($0) }
        bob.duration = breathPeriod
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .linear)
        bob.calculationMode = .linear
        bobLayer.add(bob, forKey: "idle.bob")

        // 呼吸（纵向幅度大于横向）
        let breath = CAKeyframeAnimation(keyPath: "transform")
        breath.values = (0..<samples).map { index -> NSValue in
            let s = wave(index, phase: -0.5)
            return NSValue(caTransform3D: CATransform3DMakeScale(1 - s * 0.008, 1 + s * 0.012, 1))
        }
        breath.duration = breathPeriod
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .linear)
        breath.calculationMode = .linear
        breathLayer.add(breath, forKey: "idle.breath")

        addSwayAnimation()

        // 光环：呼吸般的 5% 缩放 + 随身体起伏
        let auraPulse = CAKeyframeAnimation(keyPath: "transform.scale")
        auraPulse.values = (0..<samples).map { 1 + 0.05 * wave($0) }
        auraPulse.duration = 2 * Double.pi / 1.15
        auraPulse.repeatCount = .infinity
        auraPulse.timingFunction = CAMediaTimingFunction(name: .linear)
        auraPulse.calculationMode = .linear
        auraLayer.add(auraPulse, forKey: "idle.aura.scale")

        let baseY = petRect.midY + 8
        let auraBob = CAKeyframeAnimation(keyPath: "position.y")
        auraBob.values = (0..<samples).map { baseY + 3.6 * 0.6 * wave($0) }
        auraBob.duration = breathPeriod
        auraBob.repeatCount = .infinity
        auraBob.timingFunction = CAMediaTimingFunction(name: .linear)
        auraBob.calculationMode = .linear
        auraGroup.add(auraBob, forKey: "idle.aura.bob")
    }

    private func addSwayAnimation() {
        guard !lowPower, !hovering, window != nil else { return }
        let samples = 33
        let sway = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sway.values = (0..<samples).map { index -> CGFloat in
            CGFloat(sin(2 * .pi * Double(index) / Double(samples - 1))) * 1.25 * .pi / 180
        }
        sway.duration = 2 * Double.pi / 0.75
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .linear)
        sway.calculationMode = .linear
        swayLayer.add(sway, forKey: "idle.sway")
    }

    // MARK: - 眨眼

    private func scheduleNextBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard !isPaused, window != nil else { return }
        let delay = Double.random(in: 3.0...6.8)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.blinkNow()
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    func blinkNow() {
        guard !isPaused, window != nil else { return }
        let closed = CAKeyframeAnimation(keyPath: "opacity")
        closed.values = [0, 0, 1, 1, 0, 0]
        closed.keyTimes = [0, 0.35, 0.36, 0.72, 0.73, 1]
        closed.duration = 0.20
        let half = CAKeyframeAnimation(keyPath: "opacity")
        half.values = [0, 1, 0, 0, 1, 0]
        half.keyTimes = [0, 0.35, 0.36, 0.72, 0.73, 1]
        half.duration = 0.20

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blinkClosedLayer.add(closed, forKey: "blink.closed")
        blinkHalfLayer.add(half, forKey: "blink.half")
        CATransaction.commit()

        if Double.random(in: 0..<1) < 0.18 {
            let timer = Timer(timeInterval: 0.16, repeats: false) { [weak self] _ in
                self?.blinkNow()
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else {
            scheduleNextBlink()
        }
    }

    // MARK: - 粒子调度

    private func scheduleNextPetal() {
        petalTimer?.invalidate()
        petalTimer = nil
        guard !isPaused, petalsEnabled, !lowPower, window != nil else { return }
        let delay = Double.random(in: 0.75...1.9)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.spawnPetal()
            self?.scheduleNextPetal()
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        petalTimer = timer
    }

    private func scheduleNextSparkle() {
        sparkleTimer?.invalidate()
        sparkleTimer = nil
        guard !isPaused, !lowPower, window != nil else { return }
        let delay = Double.random(in: 2.6...5.4)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.emitSparkles(count: 1)
            self?.scheduleNextSparkle()
        }
        timer.tolerance = 0.6
        RunLoop.main.add(timer, forMode: .common)
        sparkleTimer = timer
    }

    private func stopScheduledTimers() {
        blinkTimer?.invalidate(); blinkTimer = nil
        petalTimer?.invalidate(); petalTimer = nil
        sparkleTimer?.invalidate(); sparkleTimer = nil
    }

    /// 窗口不可见（被遮挡 / 休眠）时彻底停下来，恢复时重新排程。
    func setScenePaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            stopScheduledTimers()
            layer?.speed = 0
        } else {
            layer?.speed = 1
            scheduleNextBlink()
            scheduleNextPetal()
            scheduleNextSparkle()
        }
    }

    private func clearPetals() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        petalBack.sublayers?.forEach { $0.removeFromSuperlayer() }
        petalFront.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    // MARK: - 对外动作

    func showBubble(_ text: String, duration: CGFloat = 5.5) {
        let clean = PetSecurity.sanitizeBubbleText(text)
        guard !clean.isEmpty else { return }

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
        let size = (clean as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).size
        let attributed = NSAttributedString(string: clean, attributes: attrs)

        // 上一个气泡可能还在淡出，先把它的动画停掉再复用同一个图层。
        bubbleLayer.removeAllAnimations()
        bubble = BubbleState(text: clean,
                             attributed: attributed,
                             textSize: CGSize(width: ceil(size.width), height: ceil(size.height)),
                             above: true,
                             rect: .zero,
                             sprite: nil,
                             dismissing: false)

        bubbleTimer?.invalidate()
        let clamped = PetSecurity.clampBubbleDuration(duration)
        let timer = Timer(timeInterval: TimeInterval(clamped), repeats: false) { [weak self] _ in
            self?.dismissBubble()
        }
        timer.tolerance = min(0.6, TimeInterval(clamped) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        bubbleTimer = timer

        updateBubbleLayout(appear: true)
    }

    func dismissBubble() {
        guard var state = bubble, !state.dismissing else { return }
        state.dismissing = true
        bubble = state
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        bubbleHitRect = .zero

        bubbleLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubbleLayer.opacity = 0
        bubbleLayer.transform = CATransform3DMakeScale(0.92, 0.92, 1)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.18
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: CATransform3DMakeScale(0.92, 0.92, 1))
        shrink.duration = 0.18
        bubbleLayer.add(fade, forKey: "out.fade")
        bubbleLayer.add(shrink, forKey: "out.shrink")

        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.bubble?.dismissing == true else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.bubble = nil
            self.bubbleLayer.contents = nil
            self.bubbleLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        CATransaction.commit()
    }

    func celebrate(double: Bool) {
        kickHop(double ? 360 : 250)
        kickTilt(double ? 38 : 16)
        kickSquash(double ? 1.4 : 0.8)
        emitHearts(count: double ? 10 : 6)
        blinkNow()
    }

    func happyHop() {
        kickHop(220)
        kickTilt(12)
        blinkNow()
    }

    func waterReminder() {
        // 与 assets/ruanmei_voice.m4a 的语音内容保持一致
        showBubble("休息一下，茶点时间到了。", duration: 9)
        kickHop(260)
        kickTilt(-14)
        emitDroplets()
        emitSparkles(count: 7)
        blinkNow()
    }

    // MARK: - 悬停 / 拖拽

    func setHovering(_ inside: Bool, cursor: CGPoint) {
        if hovering != inside {
            hovering = inside
            applyHoverLift(inside)
            if inside {
                swayLayer.removeAnimation(forKey: "idle.sway")
                lastLean = .nan
            } else {
                addSwayAnimation()
                resetLean()
            }
        }
        if inside { applyLean(cursor) }
    }

    /// 鼠标离开后把倾斜回正，否则会一直保持最后一次的侧倾角。
    private func resetLean() {
        let from = rotationAngle(of: tiltLayer.presentation() ?? tiltLayer)
        lastLean = .nan
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiltLayer.transform = CATransform3DIdentity
        if abs(from) > 0.0005 {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = from
            animation.toValue = 0
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tiltLayer.add(animation, forKey: "lean.reset")
        }
        CATransaction.commit()
    }

    private func applyHoverLift(_ up: Bool) {
        let from = hoverLayer.presentation()?.position.y ?? 0
        let target: CGFloat = up ? 3.0 : 0
        let samples = PetCurves.springSamples(from: from, velocity: 0, target: target,
                                              stiffness: 140, damping: 20, duration: 0.6)
        let animation = CAKeyframeAnimation(keyPath: "position.y")
        animation.values = samples
        animation.duration = 0.6
        animation.calculationMode = .linear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.position.y = target
        hoverLayer.add(animation, forKey: "hover.lift")
        CATransaction.commit()
    }

    private func applyLean(_ cursor: CGPoint) {
        guard !dragging else { return }
        let lean = clamp(-((cursor.x - petRect.midX) / max(1, petRect.width)) * 3.2, -4, 4)
        // 鼠标事件很密集，角度没变就不去动图层。
        guard abs(lean - lastLean) > 0.03 else { return }
        lastLean = lean
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiltLayer.removeAnimation(forKey: "lean.reset")
        tiltLayer.transform = CATransform3DMakeRotation(lean * .pi / 180, 0, 0, 1)
        CATransaction.commit()
    }

    func petDidBeginDrag() {
        dragging = true
        clearKickAnimations()
        applyHoverLift(true)
        NSCursor.closedHand.set()
    }

    func petDidEndDrag() {
        dragging = false
        dragVX = 0
        dragVY = 0
        relaxTilt()
        relaxSquash()
        kickHop(110)
        NSCursor.openHand.set()
        if bubble != nil { updateBubbleLayout(appear: false) }
    }

    private func applyDragDynamics() {
        let angle = clamp(-dragVX * 0.012, -13, 13) * .pi / 180
        let squash = clamp(abs(dragVX) * 0.000055, 0, 0.075)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiltLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        squashLayer.transform = CATransform3DMakeScale(1 - squash * 0.55, 1 + squash * 0.55, 1)
        CATransaction.commit()
    }

    // MARK: - 弹簧动作（预计算关键帧，仍由 CA 播放）

    private func kickHop(_ velocity: CGFloat) {
        let current = hopLayer.presentation()?.position.y ?? 0
        let from = clamp(current, -60, 60)
        let duration: CGFloat = 1.4
        let samples = PetCurves.springSamples(from: from, velocity: velocity, target: 0,
                                              stiffness: 95, damping: 8.5, duration: duration)
        let animation = CAKeyframeAnimation(keyPath: "position.y")
        animation.values = samples
        animation.duration = CFTimeInterval(duration)
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hopLayer.add(animation, forKey: "kick.hop")
        CATransaction.commit()
    }

    private func kickTilt(_ degreesPerSecond: CGFloat) {
        let from = rotationAngle(of: tiltLayer.presentation() ?? tiltLayer)
        let duration: CGFloat = 1.0
        let samples = PetCurves.springSamples(from: from,
                                              velocity: degreesPerSecond * .pi / 180,
                                              target: 0, stiffness: 130, damping: 14,
                                              duration: duration)
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = samples
        animation.duration = CFTimeInterval(duration)
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiltLayer.add(animation, forKey: "kick.tilt")
        CATransaction.commit()
    }

    private func kickSquash(_ impulse: CGFloat) {
        let from = squashValue(of: squashLayer.presentation() ?? squashLayer)
        let duration: CGFloat = 0.9
        let samples = PetCurves.springSamples(from: from, velocity: impulse, target: 0,
                                              stiffness: 150, damping: 18, duration: duration)
        let values = samples.map { value -> NSValue in
            NSValue(caTransform3D: CATransform3DMakeScale(1 - value * 0.55, 1 + value * 0.55, 1))
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = values
        animation.duration = CFTimeInterval(duration)
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        squashLayer.add(animation, forKey: "kick.squash")
        CATransaction.commit()
    }

    private func clearKickAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiltLayer.removeAnimation(forKey: "kick.tilt")
        tiltLayer.removeAnimation(forKey: "lean.reset")
        hopLayer.removeAnimation(forKey: "kick.hop")
        squashLayer.removeAnimation(forKey: "kick.squash")
        CATransaction.commit()
    }

    private func relaxTilt() {
        let from = rotationAngle(of: tiltLayer.presentation() ?? tiltLayer)
        let duration: CGFloat = 0.8
        let samples = PetCurves.springSamples(from: from, velocity: 0, target: 0,
                                              stiffness: 130, damping: 14, duration: duration)
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = samples
        animation.duration = CFTimeInterval(duration)
        animation.calculationMode = .linear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiltLayer.transform = CATransform3DIdentity
        tiltLayer.add(animation, forKey: "relax.tilt")
        CATransaction.commit()
    }

    private func relaxSquash() {
        let from = squashValue(of: squashLayer.presentation() ?? squashLayer)
        let duration: CGFloat = 0.7
        let samples = PetCurves.springSamples(from: from, velocity: 0, target: 0,
                                              stiffness: 150, damping: 18, duration: duration)
        let values = samples.map { value -> NSValue in
            NSValue(caTransform3D: CATransform3DMakeScale(1 - value * 0.55, 1 + value * 0.55, 1))
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = values
        animation.duration = CFTimeInterval(duration)
        animation.calculationMode = .linear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        squashLayer.transform = CATransform3DIdentity
        squashLayer.add(animation, forKey: "relax.squash")
        CATransaction.commit()
    }

    private func rotationAngle(of target: CALayer) -> CGFloat {
        let transform = target.transform
        return atan2(transform.m12, transform.m11)
    }

    /// 把 scaleY 反推回 -squash…+squash 的取值。
    private func squashValue(of target: CALayer) -> CGFloat {
        let transform = target.transform
        let scaleY = sqrt(transform.m12 * transform.m12 + transform.m22 * transform.m22)
        return clamp((scaleY - 1) / 0.55, -0.12, 0.12)
    }

    // MARK: - 粒子生成

    private func spawnPetal() {
        guard !isPaused, petalsEnabled, !lowPower else { return }
        let x = CGFloat.random(in: 20...max(21, bounds.width - 20))
        let size = CGFloat.random(in: 7...13)
        var particle = PetParticle(
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
            behind: Bool.random()
        )
        particle.maxLife = particle.life
        emit(particle)
    }

    private func emitHearts(count: Int) {
        let center = CGPoint(x: petRect.midX, y: petRect.minY + petRect.height * 0.28)
        let total = min(count, PetSecurity.maxParticlesPerBurst)
        for _ in 0..<total {
            let life = CGFloat.random(in: 1.3...2.1)
            emit(PetParticle(
                kind: .heart,
                position: CGPoint(x: center.x + CGFloat.random(in: -46...46),
                                  y: center.y + CGFloat.random(in: -10...40)),
                velocity: CGVector(dx: CGFloat.random(in: -26...26), dy: CGFloat.random(in: 55...120)),
                life: life, maxLife: life,
                size: CGFloat.random(in: 9...16),
                angle: CGFloat.random(in: -0.3...0.3),
                spin: CGFloat.random(in: -1.2...1.2),
                gravity: 95,
                drag: 0.4,
                color: NSColor(srgbRed: 0.94, green: 0.45, blue: 0.58, alpha: CGFloat.random(in: 0.65...0.95)),
                seed: 0
            ))
        }
    }

    private func emitDroplets() {
        let center = CGPoint(x: petRect.midX, y: petRect.minY + petRect.height * 0.3)
        for _ in 0..<PetSecurity.maxParticlesPerBurst {
            let life = CGFloat.random(in: 1.0...1.8)
            emit(PetParticle(
                kind: .droplet,
                position: CGPoint(x: center.x + CGFloat.random(in: -70...70),
                                  y: center.y + CGFloat.random(in: -20...60)),
                velocity: CGVector(dx: CGFloat.random(in: -70...70), dy: CGFloat.random(in: 80...200)),
                life: life, maxLife: life,
                size: CGFloat.random(in: 6...12),
                angle: CGFloat.random(in: -0.4...0.4),
                spin: CGFloat.random(in: -0.8...0.8),
                gravity: 260,
                drag: 0.15,
                color: Palette.water.withAlphaComponent(CGFloat.random(in: 0.6...0.95)),
                seed: 0
            ))
        }
    }

    private func emitSparkles(count: Int) {
        let total = min(count, PetSecurity.maxParticlesPerBurst)
        for _ in 0..<total {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let radius = petSize * CGFloat.random(in: 0.34...0.5)
            let life = CGFloat.random(in: 0.9...1.8)
            emit(PetParticle(
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
            ))
        }
    }

    private func visual(for particle: PetParticle) -> (image: CGImage, size: CGSize)? {
        guard let sprites else { return nil }
        switch particle.kind {
        case .petal:
            let side = particle.size * 2
            return (sprites.petal, CGSize(width: side, height: side))
        case .heart:
            return (sprites.heart, CGSize(width: particle.size, height: particle.size))
        case .droplet:
            return (sprites.droplet, CGSize(width: particle.size * 0.7, height: particle.size))
        case .sparkle:
            return (sprites.sparkle, CGSize(width: particle.size, height: particle.size))
        }
    }

    /// 一次性的粒子图层在动画结束后会被 CATransaction 的 completion 移除；
    /// 这里再加一层兜底，动画已经结束却没有被清理的图层在下次生成前清掉。
    private func pruneFinishedParticles(in container: CALayer) {
        guard let sublayers = container.sublayers else { return }
        for layer in sublayers where layer.animationKeys()?.isEmpty ?? true {
            layer.removeFromSuperlayer()
        }
    }

    /// 粒子物理在生成时一次性模拟完，播放交给 CA，主线程不再逐帧推进。
    private func emit(_ particle: PetParticle) {
        guard let visual = visual(for: particle) else { return }
        let container = particle.behind ? petalBack : petalFront
        pruneFinishedParticles(in: petalBack)
        pruneFinishedParticles(in: petalFront)
        let live = (petalBack.sublayers?.count ?? 0) + (petalFront.sublayers?.count ?? 0)
        guard live < PetSecurity.maxLiveParticles else { return }

        var body = particle
        let dt: CGFloat = 1.0 / 120.0
        let sampleInterval: CGFloat = 1.0 / 20.0
        let alphaScale = body.color.alphaComponent

        var positions: [CGPoint] = [body.position]
        var rotations: [CGFloat] = [body.angle]
        var opacities: [CGFloat] = [fade(body) * alphaScale]
        var elapsed: CGFloat = 0
        var nextSample = sampleInterval
        while body.life > 0 && elapsed < 20 {
            body.step(dt)
            elapsed += dt
            if elapsed >= nextSample {
                nextSample += sampleInterval
                positions.append(body.position)
                rotations.append(body.angle)
                opacities.append(fade(body) * alphaScale)
            }
        }
        positions.append(body.position)
        rotations.append(body.angle)
        opacities.append(0)

        let duration = CFTimeInterval(max(0.2, elapsed))
        let layer = CALayer()
        layer.contents = visual.image
        layer.contentsScale = pixelScale
        layer.contentsGravity = .resize
        layer.masksToBounds = false
        layer.bounds = CGRect(origin: .zero, size: visual.size)
        layer.position = particle.position
        layer.opacity = 0

        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = positions.map { NSValue(point: $0) }
        position.calculationMode = .linear

        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation")
        rotation.values = rotations
        rotation.calculationMode = .linear

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = opacities
        opacity.calculationMode = .linear

        let group = CAAnimationGroup()
        group.animations = [position, rotation, opacity]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.addSublayer(layer)
        CATransaction.setCompletionBlock { [weak layer] in
            layer?.removeFromSuperlayer()
        }
        layer.add(group, forKey: "fx")
        CATransaction.commit()
    }

    private func fade(_ particle: PetParticle) -> CGFloat {
        let progress = 1 - max(0, particle.life / max(0.001, particle.maxLife))
        if particle.kind == .petal {
            return min(1, particle.life / 1.5) * min(1, progress * 6)
        }
        return min(1, particle.life / 0.35)
    }

    // MARK: - 气泡排版

    private func bubbleMetrics() -> (rect: CGRect, above: Bool, tailX: CGFloat)? {
        guard let state = bubble else { return nil }
        let width = min(300, max(150, state.textSize.width + 56))
        let height = max(50, state.textSize.height + 22)
        let r = petRect

        let screenRect = window?.convertToScreen(convert(r, to: nil)) ?? r
        let petTop = screenRect.maxY
        let petBottom = screenRect.minY
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let roomAbove = visible.maxY - petTop
        let roomBelow = petBottom - visible.minY
        var above = true
        if roomAbove < height + 16 && roomBelow > roomAbove { above = false }

        var x = r.midX - width / 2
        x = clamp(x, 8, max(8, bounds.width - width - 8))
        let y = above ? r.maxY + 10 : r.minY - height - 10
        return (CGRect(x: x, y: y, width: width, height: height),
                above,
                clamp(r.midX, x + 20, x + width - 20))
    }

    private func updateBubbleLayout(appear: Bool) {
        guard var state = bubble, !state.dismissing else {
            bubbleHitRect = .zero
            return
        }
        guard let metrics = bubbleMetrics() else { return }

        let needsBake = state.sprite == nil
            || state.above != metrics.above
            || abs(state.rect.width - metrics.rect.width) > 0.5
            || abs(state.rect.height - metrics.rect.height) > 0.5
        state.above = metrics.above
        state.rect = metrics.rect
        if needsBake {
            state.sprite = PetImages.bubble(text: state.attributed,
                                            textSize: state.textSize,
                                            body: metrics.rect,
                                            above: metrics.above,
                                            tailX: metrics.tailX,
                                            scale: pixelScale)
        }
        bubble = state
        guard let sprite = state.sprite else {
            bubbleHitRect = .zero
            return
        }

        let pad = PetImages.bubbleShadowPad
        let frame = metrics.rect.insetBy(dx: -pad, dy: -pad)
        let anchorX = (metrics.tailX - frame.minX) / max(1, frame.width)
        let anchorY = ((metrics.above ? metrics.rect.minY + 2 : metrics.rect.maxY - 2) - frame.minY)
            / max(1, frame.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubbleLayer.contents = sprite.image
        bubbleLayer.contentsScale = pixelScale
        bubbleLayer.bounds = CGRect(origin: .zero, size: frame.size)
        let anchor = CGPoint(x: clamp(anchorX, 0.02, 0.98), y: clamp(anchorY, 0.02, 0.98))
        bubbleLayer.anchorPoint = anchor
        bubbleLayer.position = CGPoint(x: frame.minX + frame.width * anchor.x,
                                       y: frame.minY + frame.height * anchor.y)
        bubbleLayer.opacity = 1
        bubbleLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        bubbleHitRect = metrics.rect.insetBy(dx: -2, dy: -2)

        guard appear else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let pop = CABasicAnimation(keyPath: "transform")
        pop.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.72, 0.72, 1))
        pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.duration = 0.26
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bubbleLayer.add(fade, forKey: "in.fade")
        bubbleLayer.add(pop, forKey: "in.pop")
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bubbleHitRect.insetBy(dx: -6, dy: -6).contains(point) {
            dismissBubble()
            return
        }
        guard acceptsPoint(point) else { return }
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
        guard let window else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - pressScreen.x
        let dy = location.y - pressScreen.y
        if !dragging && hypot(dx, dy) > 4 {
            dragging = true
            controller?.petDidBeginDrag()
            petDidBeginDrag()
        }
        guard dragging else { return }
        window.setFrameOrigin(NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))

        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240.0, now - lastDragTime)
        let vx = (location.x - lastDragScreen.x) / CGFloat(dt)
        let vy = (location.y - lastDragScreen.y) / CGFloat(dt)
        dragVX = dragVX * 0.55 + vx * 0.45
        dragVY = dragVY * 0.55 + vy * 0.45
        lastDragScreen = location
        lastDragTime = now
        applyDragDynamics()
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
        setHovering(true, cursor: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false, cursor: convert(event.locationInWindow, from: nil))
        controller?.petPointerLeft()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 指针还在窗口里、但已经离开宠物本体：立刻把点击交还给桌面，
        // 不用等轮询（否则透明区域最多会吞掉 1 秒内的点击）。
        if hovering && !acceptsPoint(point) {
            setHovering(false, cursor: point)
            controller?.petPointerLeft()
            return
        }
        if hovering { applyLean(point) }
    }
}
