import AppKit

// MARK: - 小工具

@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}

@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

/// 临界阻尼弹簧，用来做呼吸、摇摆、拖拽回弹。
struct Spring {
    var value: CGFloat = 0
    var velocity: CGFloat = 0
    var target: CGFloat = 0

    mutating func step(_ dt: CGFloat, stiffness: CGFloat = 170, damping: CGFloat = 20) {
        let d = clamp(dt, 0.001, 0.05)
        let acc = -stiffness * (value - target) - damping * velocity
        velocity += acc * d
        value += velocity * d
    }

    mutating func kick(_ v: CGFloat) { velocity += v }

    mutating func reset(_ v: CGFloat) {
        value = v
        velocity = 0
        target = v
    }
}

/// 把弹簧物理一次性算成关键帧，交回给 Core Animation 播放，避免逐帧驱动。
enum PetCurves {
    static func springSamples(from: CGFloat,
                              velocity: CGFloat,
                              target: CGFloat,
                              stiffness: CGFloat,
                              damping: CGFloat,
                              duration: CGFloat,
                              fps: CGFloat = 30) -> [CGFloat] {
        var spring = Spring(value: from, velocity: velocity, target: target)
        let dt: CGFloat = 1.0 / 120.0
        let sampleStep = 1.0 / max(1, fps)
        var nextSample = sampleStep
        var elapsed: CGFloat = 0
        var samples: [CGFloat] = [from]
        while elapsed < duration {
            spring.step(dt, stiffness: stiffness, damping: damping)
            elapsed += dt
            if elapsed >= nextSample {
                nextSample += sampleStep
                samples.append(spring.value)
            }
        }
        samples.append(target)
        return samples
    }
}

enum Palette {
    static let mint = NSColor(srgbRed: 0.56, green: 0.87, blue: 0.81, alpha: 1)
    static let water = NSColor(srgbRed: 0.32, green: 0.75, blue: 0.92, alpha: 1)
    static let waterDeep = NSColor(srgbRed: 0.18, green: 0.55, blue: 0.78, alpha: 1)
    static let ink = NSColor(srgbRed: 0.16, green: 0.19, blue: 0.22, alpha: 1)
    static let petal = NSColor(srgbRed: 0.96, green: 0.76, blue: 0.82, alpha: 1)
}

// MARK: - 粒子

struct PetParticle {
    enum Kind { case petal, heart, droplet, sparkle }

    var kind: Kind
    var position: CGPoint
    var velocity: CGVector
    var life: CGFloat
    var maxLife: CGFloat
    var size: CGFloat
    var angle: CGFloat
    var spin: CGFloat
    var gravity: CGFloat
    var drag: CGFloat
    var color: NSColor
    var seed: CGFloat
    var behind: Bool = false

    mutating func step(_ dt: CGFloat) {
        life -= dt
        velocity.dx *= (1 - drag * dt)
        velocity.dy *= (1 - drag * dt)
        velocity.dy -= gravity * dt
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt
        angle += spin * dt
    }
}

// MARK: - 路径

enum Paths {
    static func heart(in rect: CGRect) -> NSBezierPath {
        let p = NSBezierPath()
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        p.move(to: CGPoint(x: rect.midX, y: y))
        p.curve(to: CGPoint(x: x, y: y + h * 0.34),
                controlPoint1: CGPoint(x: rect.midX - w * 0.22, y: y + h * 0.12),
                controlPoint2: CGPoint(x: x, y: y + h * 0.06))
        p.curve(to: CGPoint(x: rect.midX, y: y + h),
                controlPoint1: CGPoint(x: x, y: y + h * 0.78),
                controlPoint2: CGPoint(x: rect.midX - w * 0.12, y: y + h * 0.9))
        p.curve(to: CGPoint(x: x + w, y: y + h * 0.34),
                controlPoint1: CGPoint(x: rect.midX + w * 0.12, y: y + h * 0.9),
                controlPoint2: CGPoint(x: x + w, y: y + h * 0.78))
        p.curve(to: CGPoint(x: rect.midX, y: y),
                controlPoint1: CGPoint(x: x + w, y: y + h * 0.06),
                controlPoint2: CGPoint(x: rect.midX + w * 0.22, y: y + h * 0.12))
        p.close()
        return p
    }

    static func droplet(in rect: CGRect) -> NSBezierPath {
        let p = NSBezierPath()
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        p.move(to: CGPoint(x: rect.midX, y: y + h))
        p.curve(to: CGPoint(x: x + w, y: y + h * 0.34),
                controlPoint1: CGPoint(x: rect.midX + w * 0.3, y: y + h * 0.76),
                controlPoint2: CGPoint(x: x + w, y: y + h * 0.56))
        p.curve(to: CGPoint(x: rect.midX, y: y),
                controlPoint1: CGPoint(x: x + w, y: y + h * 0.08),
                controlPoint2: CGPoint(x: rect.midX + w * 0.22, y: y))
        p.curve(to: CGPoint(x: x, y: y + h * 0.34),
                controlPoint1: CGPoint(x: rect.midX - w * 0.22, y: y),
                controlPoint2: CGPoint(x: x, y: y + h * 0.08))
        p.curve(to: CGPoint(x: rect.midX, y: y + h),
                controlPoint1: CGPoint(x: x, y: y + h * 0.56),
                controlPoint2: CGPoint(x: rect.midX - w * 0.3, y: y + h * 0.76))
        p.close()
        return p
    }

    static func sparkle(in rect: CGRect) -> NSBezierPath {
        let p = NSBezierPath()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        p.move(to: CGPoint(x: c.x, y: c.y + ry))
        p.curve(to: CGPoint(x: c.x + rx, y: c.y),
                controlPoint1: CGPoint(x: c.x + rx * 0.12, y: c.y + ry * 0.12),
                controlPoint2: CGPoint(x: c.x + rx * 0.12, y: c.y + ry * 0.12))
        p.curve(to: CGPoint(x: c.x, y: c.y - ry),
                controlPoint1: CGPoint(x: c.x + rx * 0.12, y: c.y - ry * 0.12),
                controlPoint2: CGPoint(x: c.x + rx * 0.12, y: c.y - ry * 0.12))
        p.curve(to: CGPoint(x: c.x - rx, y: c.y),
                controlPoint1: CGPoint(x: c.x - rx * 0.12, y: c.y - ry * 0.12),
                controlPoint2: CGPoint(x: c.x - rx * 0.12, y: c.y - ry * 0.12))
        p.curve(to: CGPoint(x: c.x, y: c.y + ry),
                controlPoint1: CGPoint(x: c.x - rx * 0.12, y: c.y + ry * 0.12),
                controlPoint2: CGPoint(x: c.x - rx * 0.12, y: c.y + ry * 0.12))
        p.close()
        return p
    }

    /// 五瓣小花，作为飘落的花瓣
    static func blossom(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let petals = 5
        for i in 0..<petals {
            let a = rotation + CGFloat(i) * (2 * .pi / CGFloat(petals))
            let px = center.x + cos(a) * radius * 0.62
            let py = center.y + sin(a) * radius * 0.62
            let r = CGRect(x: px - radius * 0.42, y: py - radius * 0.42,
                           width: radius * 0.84, height: radius * 0.84)
            p.appendOval(in: r)
        }
        return p
    }
}
