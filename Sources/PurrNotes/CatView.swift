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
/// The cat is a single layer showing pre-rendered frames. Nothing animates on
/// its own: one timer in this view changes the frame (and, while walking, the
/// position) a fixed number of times a second, so macOS only redraws the cat
/// when it actually changes — about 24 times a second while walking and about 6
/// while sitting or sleeping. Continuously running system animations would be
/// redrawn at the display's full rate (120 Hz on ProMotion), and because the cat
/// is on every desktop that extra work made switching desktops stutter.
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

    /// Frames per second while walking (position and legs).
    static let walkingFPS: Double = 24

    private let sprite = CALayer()
    private var cache: [CatFrame.Key: CGImage] = [:]
    private var cachedBacking: CGFloat = 0
    private var downLocation = NSPoint.zero
    private var dragging = false

    private struct Loop {
        var pose: CatPose
        var facingRight: Bool
        var frames: [CatFrame]
        var images: [CGImage]
        var start: CFTimeInterval
        var duration: CFTimeInterval
        var shownIndex = -1
    }
    private struct Slide {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }
    private var loop: Loop?
    private var slideState: Slide?
    private var blinkUntil: CFTimeInterval = 0
    private var timer: Timer?
    private var timerRate: Double = 0

    private static let mirror = CATransform3DMakeScale(-1, 1, 1)

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        sprite.contentsGravity = .resize
        sprite.bounds = CGRect(origin: .zero, size: catSize)
        sprite.position = CGPoint(x: catSize.width / 2, y: catSize.height / 2)
        // No implicit fades or slides: every change shows up exactly as set.
        sprite.actions = ["contents": NSNull(), "transform": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(sprite)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Position

    /// Puts the cat's left edge at `x` (view coordinates), cancelling any slide.
    func setCatX(_ x: CGFloat) {
        slideState = nil
        withoutImplicitAnimation {
            sprite.position = CGPoint(x: x + catSize.width / 2, y: catSize.height / 2)
        }
        updateTimer()
    }

    /// Walks the cat between two positions at constant speed.
    func slide(from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        slideState = Slide(from: from, to: to, start: CACurrentMediaTime(), duration: max(duration, 0.01))
        withoutImplicitAnimation {
            sprite.position = CGPoint(x: from + catSize.width / 2, y: catSize.height / 2)
        }
        updateTimer()
    }

    /// Where the cat's left edge is drawn right now (mid-walk included).
    var presentedCatX: CGFloat? { sprite.position.x - catSize.width / 2 }

    // MARK: Appearance

    /// Shows one specific frame, stopping any running loop.
    func show(_ state: CatState) {
        loop = nil
        blinkUntil = 0
        let frame = CatFrame(state)
        let image = self.image(for: frame)
        withoutImplicitAnimation {
            sprite.contents = image
            sprite.transform = frame.mirrored ? Self.mirror : CATransform3DIdentity
        }
        updateTimer()
    }

    /// Plays a pose's animation cycle on repeat. `duration` is one full cycle.
    func play(_ pose: CatPose, facingRight: Bool, duration: CFTimeInterval) {
        let frames = CatFrame.loop(pose, facingRight: facingRight)
        let images = frames.compactMap { image(for: $0) }
        guard !frames.isEmpty, images.count == frames.count else { return }
        loop = Loop(pose: pose, facingRight: facingRight, frames: frames, images: images,
                    start: CACurrentMediaTime(), duration: max(duration, 0.05))
        blinkUntil = 0
        showLoopFrame(force: true)
        updateTimer()
    }

    /// Closes the sitting cat's eyes for a moment without disturbing its loop.
    func blink(for duration: CFTimeInterval = 0.13) {
        guard let loop, loop.pose == .sit, loop.shownIndex >= 0 else { return }
        var state = loop.frames[loop.shownIndex].state
        state.eyes = .closed
        guard let image = render(state) else { return }
        withoutImplicitAnimation { sprite.contents = image }
        blinkUntil = CACurrentMediaTime() + duration
        // A one-off wake-up to open the eyes again; the loop timer may be slower.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.tick()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving to a display with a different pixel density: redraw what is showing.
        if let loop, backingScale != cachedBacking {
            play(loop.pose, facingRight: loop.facingRight, duration: loop.duration)
        }
    }

    // MARK: Ticking

    /// The loop's natural frame rate, or the walking rate while moving.
    private var wantedRate: Double {
        if slideState != nil { return Self.walkingFPS }
        guard let loop else { return 0 }
        return min(Self.walkingFPS, max(2, Double(loop.frames.count) / loop.duration))
    }

    private func updateTimer() {
        let rate = wantedRate
        guard rate != timerRate else { return }
        timerRate = rate
        timer?.invalidate()
        timer = nil
        guard rate > 0 else { return }
        let t = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1 / rate
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // Nothing to draw while the cat's window is hidden.
        guard window?.isVisible == true else { return }
        let now = CACurrentMediaTime()
        withoutImplicitAnimation {
            if let slide = slideState {
                let t = min(1, max(0, (now - slide.start) / slide.duration))
                let x = slide.from + (slide.to - slide.from) * CGFloat(t)
                let snapped = (x * 2).rounded() / 2
                sprite.position = CGPoint(x: snapped + catSize.width / 2, y: catSize.height / 2)
                if t >= 1 { slideState = nil }
            }
            if now >= blinkUntil { showLoopFrame(force: blinkUntil > 0) ; blinkUntil = 0 }
        }
        if slideState == nil && timerRate == Self.walkingFPS { updateTimer() }
    }

    /// Debug: what the cat shows right now, and how often its timer ticks.
    var debugPresentedFrame: String {
        let flipped = sprite.transform.m11 < 0 ? " mirrored" : ""
        if let loop, loop.shownIndex >= 0 {
            return "\(loop.pose)#\(loop.shownIndex)\(flipped) @\(Int(timerRate))Hz"
        }
        return "live\(flipped) @\(Int(timerRate))Hz"
    }

    private func showLoopFrame(force: Bool) {
        guard var current = loop else { return }
        let elapsed = (CACurrentMediaTime() - current.start).truncatingRemainder(dividingBy: current.duration)
        let index = min(current.images.count - 1, max(0, Int(elapsed / current.duration * Double(current.images.count))))
        guard force || index != current.shownIndex else { return }
        current.shownIndex = index
        loop = current
        withoutImplicitAnimation {
            sprite.contents = current.images[index]
            sprite.transform = current.frames[index].mirrored ? Self.mirror : CATransform3DIdentity
        }
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
