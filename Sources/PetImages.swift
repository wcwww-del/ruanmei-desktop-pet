import AppKit

/// 把静态画面一次性烘焙成位图。运行期只由 Core Animation 合成这些位图，
/// 不再每帧调用 `draw(_:)` 做渐变、缩放和贝塞尔路径。
enum PetImages {

    /// 一张形象尺寸下烘焙好的全部素材。
    struct Sprites {
        let card: CGImage          // 投影 + 形象
        let blinkHalf: CGImage?
        let blinkClosed: CGImage?
        let aura: CGImage
        let petal: CGImage
        let heart: CGImage
        let droplet: CGImage
        let sparkle: CGImage
    }

    struct BubbleSprite {
        let image: CGImage
        /// 气泡本体（含尾巴）在图片坐标系里的位置；图片四周额外留了阴影边距。
        let body: CGRect
    }

    // 粒子的基准尺寸（pt），实际显示时按粒子自己的 size 缩放。
    static let petalRadius: CGFloat = 13
    static let petalCanvas: CGFloat = 28
    static let heartCanvas: CGFloat = 16
    static let dropletCanvas = CGSize(width: 14, height: 20)
    static let sparkleCanvas: CGFloat = 14
    static let bubbleShadowPad: CGFloat = 26

    // MARK: - 基础烘焙

    /// 在 y 轴向上的 AppKit 坐标系里绘制，得到的位图直接作为 CALayer.contents，
    /// 这样调用方写的坐标（和原来的 draw(_:) 一致）可以直接对应到图层的 frame。
    static func bake(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let pixelW = Int((size.width * scale).rounded(.up))
        let pixelH = Int((size.height * scale).rounded(.up))
        guard pixelW > 0, pixelH > 0, pixelW <= 8192, pixelH <= 8192 else { return nil }

        guard let work = CGContext(data: nil, width: pixelW, height: pixelH,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        work.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: work, flipped: false)
        draw(work)
        NSGraphicsContext.restoreGraphicsState()
        return work.makeImage()
    }

    // MARK: - 形象

    /// 与原来一致：保持长宽比、水平居中、底边贴住容器底部。
    static func artRect(imageSize: CGSize, in side: CGFloat) -> CGRect {
        let aspect = imageSize.width / max(1, imageSize.height)
        var width = side
        var height = side
        if aspect > 1 {
            height = side / aspect
        } else if aspect < 1 {
            width = side * aspect
        }
        return CGRect(x: (side - width) / 2, y: 0, width: width, height: height)
    }

    static func sprites(for effects: PetEffects, petSize: CGFloat, scale: CGFloat) -> Sprites? {
        let side = petSize
        let art = artRect(imageSize: effects.pet.size, in: side)

        let card = bake(size: CGSize(width: side, height: side), scale: scale) { ctx in
            if let shadow = effects.shadow {
                ctx.saveGState()
                ctx.setAlpha(0.55)
                shadow.draw(in: CGRect(x: 0, y: 0, width: side, height: side),
                            from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: false,
                            hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high])
                ctx.restoreGState()
            }
            effects.pet.draw(in: art,
                             from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: false,
                             hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high])
        }
        guard let card else { return nil }

        guard let aura = bake(size: CGSize(width: side * 1.2, height: side * 1.2), scale: scale, draw: { ctx in
            let diameter = side * 1.2
            let center = CGPoint(x: diameter / 2, y: diameter / 2)
            let colors = [Palette.mint.withAlphaComponent(0.14).cgColor,
                          Palette.mint.withAlphaComponent(0.0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                           colors: colors, locations: [0, 1]) else { return }
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: 1.0, y: 0.92)
            ctx.drawRadialGradient(gradient,
                                   startCenter: .zero, startRadius: side * 0.16,
                                   endCenter: .zero, endRadius: side * 0.60,
                                   options: [.drawsAfterEndLocation])
        }) else { return nil }

        guard let petal = bake(size: CGSize(width: petalCanvas, height: petalCanvas), scale: scale, draw: { _ in
            let path = Paths.blossom(center: CGPoint(x: petalCanvas / 2, y: petalCanvas / 2),
                                     radius: petalRadius, rotation: 0)
            Palette.petal.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 0.6
            path.stroke()
        }) else { return nil }

        guard let heart = bake(size: CGSize(width: heartCanvas, height: heartCanvas), scale: scale, draw: { _ in
            let rect = CGRect(x: 0, y: 0, width: heartCanvas, height: heartCanvas)
            NSColor(srgbRed: 0.94, green: 0.45, blue: 0.58, alpha: 1).setFill()
            Paths.heart(in: rect).fill()
        }) else { return nil }

        guard let droplet = bake(size: dropletCanvas, scale: scale, draw: { ctx in
            let rect = CGRect(x: 0, y: 0, width: dropletCanvas.width, height: dropletCanvas.height)
            Palette.water.setFill()
            Paths.droplet(in: rect).fill()
            NSColor.white.withAlphaComponent(0.55).setFill()
            ctx.fillEllipse(in: CGRect(x: dropletCanvas.width * 0.28,
                                       y: dropletCanvas.height * 0.34,
                                       width: dropletCanvas.width * 0.21,
                                       height: dropletCanvas.height * 0.15))
        }) else { return nil }

        guard let sparkle = bake(size: CGSize(width: sparkleCanvas, height: sparkleCanvas), scale: scale, draw: { _ in
            let rect = CGRect(x: 0, y: 0, width: sparkleCanvas, height: sparkleCanvas)
            Palette.mint.withAlphaComponent(0.9).setFill()
            Paths.sparkle(in: rect).fill()
        }) else { return nil }

        return Sprites(card: card,
                       blinkHalf: overlaySprite(effects.blinkHalf, art: art, side: side, scale: scale),
                       blinkClosed: overlaySprite(effects.blinkClosed, art: art, side: side, scale: scale),
                       aura: aura, petal: petal, heart: heart, droplet: droplet, sparkle: sparkle)
    }

    private static func overlaySprite(_ image: NSImage?, art: CGRect, side: CGFloat, scale: CGFloat) -> CGImage? {
        guard let image else { return nil }
        return bake(size: CGSize(width: side, height: side), scale: scale) { _ in
            image.draw(in: art,
                       from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: false,
                       hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high])
        }
    }

    // MARK: - 气泡

    /// 气泡连同阴影、水滴图标、文字一起烘焙，之后只有缩放/透明度动画。
    static func bubble(text: NSAttributedString,
                       textSize: CGSize,
                       body: CGRect,
                       above: Bool,
                       tailX: CGFloat,
                       scale: CGFloat) -> BubbleSprite? {
        let pad = bubbleShadowPad
        let canvas = CGSize(width: body.width + pad * 2, height: body.height + pad * 2)
        let rect = CGRect(x: pad, y: pad, width: body.width, height: body.height)
        // tailX 传进来的是视图坐标，这里换算到图片自身的坐标系。
        let tailX = tailX - body.minX + pad

        guard let image = bake(size: canvas, scale: scale, draw: { ctx in
            let shape = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
            let tail = NSBezierPath()
            if above {
                tail.move(to: CGPoint(x: tailX - 8, y: rect.minY + 1))
                tail.line(to: CGPoint(x: tailX + 8, y: rect.minY + 1))
                tail.line(to: CGPoint(x: tailX, y: rect.minY - 8))
            } else {
                tail.move(to: CGPoint(x: tailX - 8, y: rect.maxY - 1))
                tail.line(to: CGPoint(x: tailX + 8, y: rect.maxY - 1))
                tail.line(to: CGPoint(x: tailX, y: rect.maxY + 8))
            }
            tail.close()
            shape.append(tail)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
            NSColor(srgbRed: 0.995, green: 0.992, blue: 0.975, alpha: 0.97).setFill()
            shape.fill()
            ctx.restoreGState()

            NSColor.white.withAlphaComponent(0.85).setStroke()
            shape.lineWidth = 0.8
            shape.stroke()

            // 水滴图标
            let iconRect = CGRect(x: rect.minX + 14, y: rect.midY - 11, width: 18, height: 22)
            let drop = Paths.droplet(in: iconRect)
            if let gradient = NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.86, blue: 0.97, alpha: 1),
                                                  Palette.waterDeep]) {
                gradient.draw(in: drop, angle: -90)
            } else {
                Palette.waterDeep.setFill()
                drop.fill()
            }
            NSColor.white.withAlphaComponent(0.55).setFill()
            ctx.fillEllipse(in: CGRect(x: iconRect.minX + 5, y: iconRect.midY - 2, width: 3.2, height: 4.6))

            // 文案
            let textRect = CGRect(x: iconRect.maxX + 10,
                                  y: rect.midY - textSize.height / 2,
                                  width: rect.width - (iconRect.maxX + 10 - rect.minX) - 12,
                                  height: textSize.height + 2)
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }) else { return nil }

        return BubbleSprite(image: image, body: rect)
    }
}
