import AppKit

enum CatPose { case walk, sit, sleep, held }
enum EyeStyle { case open, closed, happy, wide }

/// Everything needed to draw one frame of the cat.
struct CatState {
    var pose: CatPose = .sit
    var facingRight = true
    /// Walk cycle angle in radians; one full stride per 2π.
    var phase: CGFloat = 0
    /// Free-running clock in seconds, drives tail sway, breathing and the sleepy z's.
    var time: CGFloat = 0
    var eyes: EyeStyle = .open
    /// 0...1 progress of the floating hearts shown after a click, nil when inactive.
    var hearts: CGFloat? = nil
}

/// A `CatState` snapped onto a short repeating loop, so identical frames can be
/// drawn once and reused instead of being rasterised on every tick.
struct CatFrame {
    struct Key: Hashable {
        var pose: Int
        var step: Int
        var facingRight: Bool
    }

    /// Seconds for one breath (and one lap of the z's) while asleep.
    static let sleepLoop: CGFloat = 2 * .pi / 1.6
    /// Seconds for one breath and tail flick while sitting.
    static let sitLoop: CGFloat = .pi
    /// Walk-cycle radians covered by the walking loop (two strides).
    private static let walkSpan: CGFloat = 4 * .pi

    /// How long the walking loop lasts at a given speed in points per second.
    static func walkLoopDuration(speed: CGFloat) -> CGFloat {
        walkSpan / (max(speed, 1) * 0.16)   // 0.16 rad of leg swing per point travelled
    }

    /// Every frame of a pose's repeating animation, in order.
    static func loop(_ pose: CatPose, facingRight: Bool) -> [CatFrame] {
        let count: Int
        let span: CGFloat
        switch pose {
        case .walk: (count, span) = (walkSteps, walkSpan)
        case .sit: (count, span) = (sitSteps, sitLoop)
        case .sleep: (count, span) = (sleepSteps, sleepLoop)
        case .held: return []
        }
        return (0..<count).map { i in
            var s = CatState(pose: pose, facingRight: facingRight)
            let value = (CGFloat(i) + 0.5) * span / CGFloat(count)
            if pose == .walk { s.phase = value } else { s.time = value }
            s.eyes = pose == .sleep ? .closed : .open
            return CatFrame(s)
        }
    }
    private static let walkSteps = 24   // spans two strides, so the tail can sway slower than the legs
    private static let sitSteps = 16
    private static let sleepSteps = 24

    /// The state to draw.
    var state: CatState
    /// Cache key, or nil for one-off frames (hearts, blinks, being carried).
    var key: Key?
    /// True when `state` was drawn facing right and should be mirrored on screen.
    var mirrored = false

    init(_ s: CatState) {
        var q = s
        var step = 0
        var poseID = 0
        var cacheable = s.hearts == nil

        switch s.pose {
        case .walk:
            poseID = 0
            let loop = Self.walkSpan
            step = Self.step(s.phase, loop: loop, count: Self.walkSteps)
            q.phase = CGFloat(step) * loop / CGFloat(Self.walkSteps)
            q.time = q.phase / 6   // tail sway = sin(time * 3) = sin(phase / 2)
            cacheable = cacheable && s.eyes == .open
        case .sit:
            poseID = 1
            step = Self.step(s.time, loop: Self.sitLoop, count: Self.sitSteps)
            q.time = CGFloat(step) * Self.sitLoop / CGFloat(Self.sitSteps)
            cacheable = cacheable && s.eyes == .open
        case .sleep:
            poseID = 2
            step = Self.step(s.time, loop: Self.sleepLoop, count: Self.sleepSteps)
            q.time = CGFloat(step) * Self.sleepLoop / CGFloat(Self.sleepSteps)
        case .held:
            cacheable = false
        }

        if cacheable {
            // The z's are text and must not be mirrored, so sleeping frames are
            // cached per direction; the other poses share one image and flip it.
            if s.pose == .sleep {
                key = Key(pose: poseID, step: step, facingRight: s.facingRight)
            } else {
                q.facingRight = true
                mirrored = !s.facingRight
                key = Key(pose: poseID, step: step, facingRight: true)
            }
        }
        state = q
    }

    private static func step(_ value: CGFloat, loop: CGFloat, count: Int) -> Int {
        let t = value.truncatingRemainder(dividingBy: loop) / loop
        return min(count - 1, max(0, Int(t * CGFloat(count))))
    }
}

/// Draws the cat procedurally into the current graphics context.
/// All coordinates are in a 120×110 design space with the paws resting on y = 6.
enum CatRenderer {
    static let baseSize = CGSize(width: 120, height: 110)
    /// Design-space y of the bottom of the paws.
    static let groundY: CGFloat = 6

    private static let fur = rgb(0xF6A95C)
    private static let furDark = rgb(0xDE8A3E)
    private static let cream = rgb(0xFFF3E0)
    private static let creamDark = rgb(0xF0DCC0)
    private static let outline = rgb(0x5B3A24)
    private static let pink = rgb(0xF59AA5)
    private static let eye = rgb(0x3B2A1F)
    private static let heart = rgb(0xF0506E)

    static func draw(_ s: CatState, scale: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        ctx.saveGState()
        if !s.facingRight {
            ctx.translateBy(x: baseSize.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        switch s.pose {
        case .walk: drawStanding(s, ctx: ctx, dangling: false)
        case .held: drawStanding(s, ctx: ctx, dangling: true)
        case .sit: drawSitting(s)
        case .sleep: drawSleeping(s)
        }
        ctx.restoreGState()

        // Text overlays are drawn unmirrored so glyphs never flip.
        drawOverlays(s)
        ctx.restoreGState()
    }

    // MARK: Poses

    private static func drawStanding(_ s: CatState, ctx: CGContext, dangling: Bool) {
        let bob = dangling ? 0 : sin(s.phase * 2) * 1.1
        let sway = sin(s.time * 3)

        if dangling {
            tail(from: pt(31, 35), c1: pt(20, 33), c2: pt(14 + sway * 2, 25), to: pt(13 + sway * 3, 15))
        } else {
            shadow(NSRect(x: 28, y: 2, width: 68, height: 8))
            tail(from: pt(31, 37 + bob), c1: pt(16, 35 + bob), c2: pt(21 + sway * 3, 51), to: pt(15 + sway * 4, 62 + bob))
        }

        let amp: CGFloat = dangling ? 0.28 : 0.5
        let p = dangling ? s.time * 13 : s.phase
        let hipY = 22 + bob
        // Diagonal gait: far-back moves with near-front, and vice versa.
        leg(hip: pt(43, hipY), angle: sin(p + .pi) * amp, far: true, ctx: ctx)
        leg(hip: pt(69, hipY), angle: sin(p) * amp, far: true, ctx: ctx)
        leg(hip: pt(36, hipY), angle: sin(p) * amp, far: false, ctx: ctx)
        leg(hip: pt(62, hipY), angle: sin(p + .pi) * amp, far: false, ctx: ctx)

        let body = NSBezierPath(roundedRect: NSRect(x: 28, y: 19 + bob, width: 50, height: 27),
                                xRadius: 13.5, yRadius: 13.5)
        fur.setFill()
        body.fill()
        clipped(to: body) {
            for x in [42, 51, 60] as [CGFloat] {
                stripe(from: pt(x, 48 + bob), to: pt(x + 2, 38 + bob), width: 3.2)
            }
        }
        strokeOutline(body)

        drawHead(at: pt(83, 48 + bob * 1.2), eyes: s.eyes)
    }

    private static func drawSitting(_ s: CatState) {
        let breathe = sin(s.time * 2) * 0.5
        let sway = sin(s.time * 2 + 1)

        shadow(NSRect(x: 34, y: 2, width: 58, height: 8))
        tail(from: pt(74, 13), c1: pt(90, 8), c2: pt(101, 14), to: pt(96 + sway * 2.5, 28 + abs(sway)))

        let body = NSBezierPath(ovalIn: NSRect(x: 41, y: 6, width: 38, height: 43 + breathe))
        fur.setFill()
        body.fill()
        clipped(to: body) {
            cream.setFill()
            NSBezierPath(ovalIn: NSRect(x: 50, y: 9, width: 20, height: 28)).fill()
        }
        strokeOutline(body)

        paint(NSBezierPath(ovalIn: NSRect(x: 48.5, y: 5, width: 11.5, height: 8)), fill: cream)
        paint(NSBezierPath(ovalIn: NSRect(x: 60, y: 5, width: 11.5, height: 8)), fill: cream)

        drawHead(at: pt(60, 59 + breathe), eyes: s.eyes)
    }

    private static func drawSleeping(_ s: CatState) {
        let breathe = sin(s.time * 1.6) * 1.2

        shadow(NSRect(x: 22, y: 2, width: 84, height: 8))

        let body = NSBezierPath(ovalIn: NSRect(x: 28, y: 6, width: 60, height: 29 + breathe))
        fur.setFill()
        body.fill()
        clipped(to: body) {
            for x in [46, 56, 66] as [CGFloat] {
                stripe(from: pt(x, 37 + breathe), to: pt(x + 1.5, 27 + breathe), width: 3.2)
            }
        }
        strokeOutline(body)

        // The tail wraps around the front of the loaf.
        tail(from: pt(34, 16), c1: pt(18, 12), c2: pt(28, 5), to: pt(58, 8.5))

        drawHead(at: pt(85, 23 + breathe * 0.3), eyes: .closed)
    }

    // MARK: Parts

    private static func drawHead(at c: CGPoint, eyes: EyeStyle) {
        // Ears sit behind the head.
        for side in [-1, 1] as [CGFloat] {
            let ear = NSBezierPath()
            ear.move(to: pt(c.x + side * 16, c.y + 5))
            ear.line(to: pt(c.x + side * 13.5, c.y + 23))
            ear.line(to: pt(c.x + side * 2, c.y + 13))
            ear.close()
            paint(ear, fill: fur)

            let inner = NSBezierPath()
            inner.move(to: pt(c.x + side * 13, c.y + 9))
            inner.line(to: pt(c.x + side * 12, c.y + 19))
            inner.line(to: pt(c.x + side * 5.5, c.y + 13))
            inner.close()
            pink.setFill()
            inner.fill()
        }

        let head = NSBezierPath(ovalIn: NSRect(x: c.x - 18, y: c.y - 15, width: 36, height: 30))
        fur.setFill()
        head.fill()
        clipped(to: head) {
            for dx in [-5, 0, 5] as [CGFloat] {
                stripe(from: pt(c.x + dx, c.y + 16), to: pt(c.x + dx * 0.8, c.y + 9), width: 2.6)
            }
            cream.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 9, y: c.y - 14, width: 18, height: 13)).fill()
        }
        strokeOutline(head)

        // Blush
        pink.withAlphaComponent(0.5).setFill()
        for side in [-1, 1] as [CGFloat] {
            NSBezierPath(ovalIn: NSRect(x: c.x + side * 12.5 - 2.8, y: c.y - 7.5, width: 5.6, height: 3.4)).fill()
        }

        // Eyes
        for side in [-1, 1] as [CGFloat] {
            let e = pt(c.x + side * 7.5, c.y - 0.5)
            switch eyes {
            case .open, .wide:
                let w: CGFloat = eyes == .wide ? 6.6 : 5
                let h: CGFloat = eyes == .wide ? 7.6 : 6.6
                eye.setFill()
                NSBezierPath(ovalIn: NSRect(x: e.x - w / 2, y: e.y - h / 2, width: w, height: h)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: e.x - 0.2, y: e.y + 0.6, width: 2, height: 2)).fill()
            case .closed, .happy:
                let bend: CGFloat = eyes == .happy ? 3.6 : -3.2
                let lid = NSBezierPath()
                lid.move(to: pt(e.x - 3, e.y))
                lid.quad(to: pt(e.x + 3, e.y), control: pt(e.x, e.y + bend))
                lid.lineWidth = 1.6
                lid.lineCapStyle = .round
                eye.setStroke()
                lid.stroke()
            }
        }

        // Nose and mouth
        let nose = NSBezierPath()
        nose.move(to: pt(c.x - 2.3, c.y - 5))
        nose.line(to: pt(c.x + 2.3, c.y - 5))
        nose.line(to: pt(c.x, c.y - 7.4))
        nose.close()
        nose.lineJoinStyle = .round
        pink.setFill()
        nose.fill()
        outline.setStroke()
        nose.lineWidth = 0.8
        nose.stroke()

        let mouth = NSBezierPath()
        mouth.move(to: pt(c.x - 4, c.y - 8.6))
        mouth.quad(to: pt(c.x, c.y - 7.8), control: pt(c.x - 2, c.y - 11.2))
        mouth.quad(to: pt(c.x + 4, c.y - 8.6), control: pt(c.x + 2, c.y - 11.2))
        mouth.lineWidth = 1.2
        mouth.lineCapStyle = .round
        mouth.lineJoinStyle = .round
        outline.setStroke()
        mouth.stroke()

        // Whiskers
        outline.withAlphaComponent(0.55).setStroke()
        for side in [-1, 1] as [CGFloat] {
            for (y0, y1) in [(-4.5, -3.0), (-7.5, -9.0)] as [(CGFloat, CGFloat)] {
                let w = NSBezierPath()
                w.move(to: pt(c.x + side * 14, c.y + y0))
                w.line(to: pt(c.x + side * 23, c.y + y1))
                w.lineWidth = 0.9
                w.lineCapStyle = .round
                w.stroke()
            }
        }
    }

    private static func leg(hip: CGPoint, angle: CGFloat, far: Bool, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: hip.x, y: hip.y)
        ctx.rotate(by: angle)
        paint(NSBezierPath(roundedRect: NSRect(x: -4, y: -14, width: 8, height: 17), xRadius: 4, yRadius: 4),
              fill: far ? furDark : fur)
        paint(NSBezierPath(ovalIn: NSRect(x: -4.5, y: -16, width: 10.5, height: 6.5)),
              fill: far ? creamDark : cream)
        ctx.restoreGState()
    }

    private static func tail(from a: CGPoint, c1: CGPoint, c2: CGPoint, to b: CGPoint) {
        let p = NSBezierPath()
        p.move(to: a)
        p.curve(to: b, controlPoint1: c1, controlPoint2: c2)
        p.lineCapStyle = .round
        outline.setStroke()
        p.lineWidth = 10
        p.stroke()
        fur.setStroke()
        p.lineWidth = 6
        p.stroke()
    }

    private static func stripe(from a: CGPoint, to b: CGPoint, width: CGFloat) {
        let p = NSBezierPath()
        p.move(to: a)
        p.line(to: b)
        p.lineWidth = width
        p.lineCapStyle = .round
        furDark.setStroke()
        p.stroke()
    }

    private static func shadow(_ rect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    // MARK: Overlays

    private static func drawOverlays(_ s: CatState) {
        func mx(_ x: CGFloat) -> CGFloat { s.facingRight ? x : baseSize.width - x }

        if s.pose == .sleep {
            for i in 0..<3 {
                let p = (s.time / CatFrame.sleepLoop + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
                let alpha = sin(p * .pi)
                let x = 97 + p * 9 + sin(p * 6) * 2
                glyph("z", center: pt(mx(x), 44 + p * 36), size: 8 + p * 7,
                      color: NSColor.white.withAlphaComponent(alpha),
                      stroke: outline.withAlphaComponent(alpha))
            }
        }

        if let p = s.hearts {
            let top: CGPoint
            switch s.pose {
            case .walk, .held: top = pt(83, 73)
            case .sit: top = pt(60, 80)
            case .sleep: top = pt(85, 46)
            }
            let alpha = max(0, 1 - p * p)
            glyph("♥", center: pt(mx(top.x) - 5, top.y + 4 + p * 12), size: 13,
                  color: heart.withAlphaComponent(alpha), stroke: nil)
            let late = max(0, p - 0.25) / 0.75
            if p > 0.25 {
                glyph("♥", center: pt(mx(top.x) + 8, top.y + 2 + late * 11), size: 9,
                      color: heart.withAlphaComponent(max(0, 1 - late * late)), stroke: nil)
            }
        }
    }

    private static func glyph(_ text: String, center: CGPoint, size: CGFloat, color: NSColor, stroke: NSColor?) {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: color,
        ]
        if let stroke {
            attrs[.strokeColor] = stroke
            attrs[.strokeWidth] = -9.0
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        str.draw(at: pt(center.x - sz.width / 2, center.y - sz.height / 2))
    }

    // MARK: Helpers

    private static func paint(_ path: NSBezierPath, fill: NSColor) {
        fill.setFill()
        path.fill()
        strokeOutline(path)
    }

    private static func strokeOutline(_ path: NSBezierPath) {
        outline.setStroke()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
    }

    private static func clipped(to path: NSBezierPath, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

private extension NSBezierPath {
    /// Quadratic curve, expressed as a cubic so it works before macOS 14.
    func quad(to p: CGPoint, control c: CGPoint) {
        let p0 = currentPoint
        curve(to: p,
              controlPoint1: CGPoint(x: p0.x + (c.x - p0.x) * 2 / 3, y: p0.y + (c.y - p0.y) * 2 / 3),
              controlPoint2: CGPoint(x: p.x + (c.x - p.x) * 2 / 3, y: p.y + (c.y - p.y) * 2 / 3))
    }
}
