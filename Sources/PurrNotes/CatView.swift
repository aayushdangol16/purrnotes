import AppKit
import QuartzCore

/// The transparent, borderless window the cat lives in. It floats above normal
/// windows on every Space and never takes keyboard focus.
///
/// While the cat is on the ground the window is a thin strip along the bottom of
/// the screen and the cat slides around inside it. Clicks pass straight through
/// (`ignoresMouseEvents`) except while the pointer is actually over the cat.
final class PetWindow: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the cat and turns mouse input into click / drag callbacks.
///
/// The cat is a single layer. Its walk, sit and sleep cycles are handed to Core
/// Animation as looping image sequences, and walking across the screen is one
/// position animation, so the system's compositor does the per-frame work and
/// the app itself stays asleep until the cat changes its mind.
final class CatView: NSView {
    /// Size of the cat sprite in points.
    var catSize = CatRenderer.baseSize {
        didSet {
            guard catSize != oldValue else { return }
            cache.removeAll()
            withoutImplicitAnimation {
                sprite.bounds = CGRect(origin: .zero, size: catSize)
                sprite.position.y = catSize.height / 2
            }
        }
    }

    /// Mouse went down on the cat; the point is in screen coordinates.
    var onPress: ((NSPoint) -> Void)?
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    /// Called with the pointer's screen location while dragging.
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// True between mouse-down and mouse-up on the cat.
    private(set) var isPressed = false

    private let sprite = CALayer()
    private var cache: [CatFrame.Key: CGImage] = [:]
    private var cachedBacking: CGFloat = 0
    private var loop: (pose: CatPose, facingRight: Bool, start: CFTimeInterval, duration: CFTimeInterval)?
    private var downLocation = NSPoint.zero
    private var dragging = false

    private static let mirror = CATransform3DMakeScale(-1, 1, 1)

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        sprite.contentsGravity = .resize
        sprite.bounds = CGRect(origin: .zero, size: catSize)
        sprite.position = CGPoint(x: catSize.width / 2, y: catSize.height / 2)
        // No implicit fades or slides: only the animations added below should run.
        sprite.actions = ["contents": NSNull(), "transform": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(sprite)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Position

    /// Puts the cat's left edge at `x` (view coordinates), cancelling any slide.
    func setCatX(_ x: CGFloat) {
        withoutImplicitAnimation {
            sprite.removeAnimation(forKey: "slide")
            sprite.position = CGPoint(x: x + catSize.width / 2, y: catSize.height / 2)
        }
    }

    /// Glides the cat between two positions at constant speed.
    func slide(from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        let half = catSize.width / 2
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = from + half
        move.toValue = to + half
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        withoutImplicitAnimation {
            sprite.position.x = to + half
            sprite.add(move, forKey: "slide")
        }
    }

    /// Where the cat's left edge is on screen right now, mid-slide included.
    var presentedCatX: CGFloat? {
        (sprite.presentation()?.position.x).map { $0 - catSize.width / 2 }
    }

    // MARK: Appearance

    /// Shows one specific frame, stopping any running loop.
    func show(_ state: CatState) {
        loop = nil
        let frame = CatFrame(state)
        let image = self.image(for: frame)
        withoutImplicitAnimation {
            sprite.removeAnimation(forKey: "loop")
            sprite.removeAnimation(forKey: "blink")
            sprite.contents = image
            sprite.transform = frame.mirrored ? Self.mirror : CATransform3DIdentity
        }
    }

    /// Plays a pose's animation cycle on repeat. `duration` is one full cycle.
    func play(_ pose: CatPose, facingRight: Bool, duration: CFTimeInterval) {
        let frames = CatFrame.loop(pose, facingRight: facingRight)
        let images = frames.compactMap { image(for: $0) }
        guard !frames.isEmpty, images.count == frames.count else { return }

        let cycle = CAKeyframeAnimation(keyPath: "contents")
        cycle.values = images
        cycle.keyTimes = (0...images.count).map { NSNumber(value: Double($0) / Double(images.count)) }
        cycle.calculationMode = .discrete
        cycle.duration = duration
        cycle.repeatCount = .infinity

        withoutImplicitAnimation {
            sprite.removeAnimation(forKey: "blink")
            sprite.contents = images[0]
            sprite.transform = frames[0].mirrored ? Self.mirror : CATransform3DIdentity
            sprite.add(cycle, forKey: "loop")
        }
        loop = (pose, facingRight, CACurrentMediaTime(), duration)
    }

    /// Closes the sitting cat's eyes for a moment without disturbing its loop.
    func blink(for duration: CFTimeInterval = 0.13) {
        guard let loop, loop.pose == .sit, loop.duration > 0 else { return }
        let frames = CatFrame.loop(.sit, facingRight: loop.facingRight)
        guard !frames.isEmpty else { return }
        let elapsed = (CACurrentMediaTime() - loop.start).truncatingRemainder(dividingBy: loop.duration)
        let index = min(frames.count - 1, max(0, Int(elapsed / loop.duration * Double(frames.count))))
        var state = frames[index].state
        state.eyes = .closed
        guard let image = render(state) else { return }

        let lids = CAKeyframeAnimation(keyPath: "contents")
        lids.values = [image]
        lids.keyTimes = [0, 1]
        lids.calculationMode = .discrete
        lids.duration = duration
        sprite.add(lids, forKey: "blink")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving to a display with a different pixel density: redraw what is showing.
        if let loop, backingScale != cachedBacking {
            play(loop.pose, facingRight: loop.facingRight, duration: loop.duration)
        }
    }

    /// Debug: which cached frame the compositor is showing at this instant.
    var debugPresentedFrame: String {
        guard let shown = sprite.presentation(), let contents = shown.contents else { return "nothing" }
        let flipped = shown.transform.m11 < 0 ? " mirrored" : ""
        if let key = cache.first(where: { $0.value === (contents as AnyObject) })?.key {
            return "\(["walk", "sit", "sleep"][key.pose])#\(key.step)\(flipped)"
        }
        return "live\(flipped)"
    }

    // MARK: Frames

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func image(for frame: CatFrame) -> CGImage? {
        if cachedBacking != backingScale {
            cachedBacking = backingScale
            cache.removeAll()
        }
        guard let key = frame.key else { return render(frame.state) }
        if let hit = cache[key] { return hit }
        let image = render(frame.state)
        cache[key] = image
        return image
    }

    private func render(_ s: CatState) -> CGImage? {
        let width = Int((catSize.width * backingScale).rounded())
        let height = Int((catSize.height * backingScale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        CatRenderer.draw(s, scale: CGFloat(width) / CatRenderer.baseSize.width)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        dragging = false
        downLocation = NSEvent.mouseLocation
        onPress?(downLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - downLocation.x, p.y - downLocation.y) > 5 {
            dragging = true
            onDragBegan?()
        }
        if dragging { onDragMoved?(p) }
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if dragging {
            dragging = false
            onDragEnded?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
