import AppKit
import QuartzCore

/// Owns the cat's window and runs its little brain: wander along the bottom of
/// the screen, sit, blink, nap, get picked up and dropped.
///
/// The controller is event-driven. It decides what the cat does next, hands the
/// animation to `CatView`, and sets a one-shot timer for when that behaviour
/// ends. A per-frame clock only runs for the brief moments that need one
/// (floating hearts, being carried, falling).
@MainActor
final class PetController: NSObject {
    private enum Mode { case walking, sitting, sleeping, held, falling }

    private enum Keys {
        static let scale = "catScale"
        static let stayPut = "catStayPut"
        static let hidden = "catHidden"
    }

    static let sizes: [(name: String, scale: CGFloat)] = [("Small", 0.75), ("Medium", 1.0), ("Large", 1.35)]

    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)? {
        didSet { view.menuProvider = menuProvider }
    }

    /// While the notes window is open the cat sits still next to it.
    var notesOpen = false {
        didSet {
            guard notesOpen != oldValue, !isHidden, heartTime == nil else { return }
            if notesOpen {
                if mode == .walking || mode == .sleeping { sit(for: 1) }
            } else if mode == .sitting {
                sit(for: .random(in: 1...2.5))
            }
        }
    }

    var scale: CGFloat {
        didSet {
            guard scale != oldValue else { return }
            UserDefaults.standard.set(Double(scale), forKey: Keys.scale)
            leaveCurrentMode()
            let midX = origin.x + view.catSize.width / 2
            view.catSize = catSize
            origin.x = midX - catSize.width / 2
            heartTime = nil
            sit(for: 1)
        }
    }

    var stayPut: Bool {
        didSet {
            UserDefaults.standard.set(stayPut, forKey: Keys.stayPut)
            if stayPut, mode == .walking { sit(for: 3) }
        }
    }

    var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            UserDefaults.standard.set(isHidden, forKey: Keys.hidden)
            if isHidden {
                leaveCurrentMode()
                heartTime = nil
                updateTimers()
                window.orderOut(nil)
            } else {
                window.orderFrontRegardless()
                sit(for: 1)
            }
        }
    }

    /// The cat's rectangle on screen right now.
    var frame: NSRect {
        NSRect(x: currentX, y: origin.y, width: catSize.width, height: catSize.height)
    }

    private(set) var screen: NSScreen?

    private let window: PetWindow
    private let view: CatView

    private var mode: Mode = .sitting
    /// Bottom-left corner of the cat in screen coordinates. While walking this is
    /// where the walk started; `currentX` gives the live position.
    private var origin = CGPoint.zero
    private var cat = CatState()

    private var walkFrom: CGFloat = 0
    private var walkTo: CGFloat = 0
    private var walkStart: CFTimeInterval = 0
    private var walkDuration: CFTimeInterval = 0

    private var grabOffset = CGPoint.zero
    private var fallVelocity: CGFloat = 0
    private var heartTime: CGFloat?
    private var lastTick = CACurrentMediaTime()

    private var stateTimer: Timer?   // ends the current walk / sit / nap
    private var blinkTimer: Timer?
    private var tickTimer: Timer?    // 30 Hz, only for hearts, carrying and falling
    private var mouseTimer: Timer?   // decides whether clicks should reach the cat

    override init() {
        let defaults = UserDefaults.standard
        let saved = CGFloat(defaults.double(forKey: Keys.scale))
        scale = saved > 0 ? saved : 1.0
        stayPut = defaults.bool(forKey: Keys.stayPut)
        isHidden = defaults.bool(forKey: Keys.hidden)

        let size = Self.catSize(for: scale)
        window = PetWindow(size: size)
        view = CatView(frame: NSRect(origin: .zero, size: size))
        view.catSize = size
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        screen = NSScreen.main ?? NSScreen.screens.first
        super.init()

        view.onPress = { [weak self] in self?.pressed(at: $0) }
        view.onClick = { [weak self] in self?.clicked() }
        view.onDragBegan = { [weak self] in self?.dragBegan() }
        view.onDragMoved = { [weak self] in self?.dragMoved(to: $0) }
        view.onDragEnded = { [weak self] in self?.dragEnded() }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func start() {
        origin = CGPoint(x: .random(in: xRange), y: floorY)
        cat.facingRight = Bool.random()
        guard !isHidden else { return }
        window.orderFrontRegardless()
        sit(for: 1.2)
    }

    // MARK: Geometry

    private static func catSize(for scale: CGFloat) -> NSSize {
        NSSize(width: (CatRenderer.baseSize.width * scale).rounded(),
               height: (CatRenderer.baseSize.height * scale).rounded())
    }

    private var catSize: NSSize { Self.catSize(for: scale) }

    private var activeScreen: NSScreen? {
        if let screen, NSScreen.screens.contains(screen) { return screen }
        screen = NSScreen.main ?? NSScreen.screens.first
        return screen
    }

    /// Screen y that puts the paws on top of the Dock (or the screen edge).
    private var floorY: CGFloat {
        guard let s = activeScreen else { return 0 }
        return s.visibleFrame.minY - (CatRenderer.groundY - 1) * scale
    }

    private var xRange: ClosedRange<CGFloat> {
        guard let s = activeScreen else { return 0...0 }
        let lo = s.frame.minX
        return lo...max(lo, s.frame.maxX - catSize.width)
    }

    /// The strip along the bottom of the screen that the cat walks in.
    private var stripFrame: NSRect {
        guard let s = activeScreen else { return NSRect(origin: origin, size: catSize) }
        return NSRect(x: s.frame.minX, y: floorY, width: s.frame.width, height: catSize.height)
    }

    private var currentX: CGFloat {
        guard mode == .walking, walkDuration > 0 else { return origin.x }
        let t = min(1, max(0, (CACurrentMediaTime() - walkStart) / walkDuration))
        return walkFrom + (walkTo - walkFrom) * CGFloat(t)
    }

    private func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    /// Sizes the window for the current mode and puts the cat where `origin` says.
    /// On the ground the window is the full-width strip; in the air it hugs the cat.
    private func place() {
        guard activeScreen != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if mode == .held || mode == .falling {
            let target = NSRect(origin: CGPoint(x: snap(origin.x), y: snap(origin.y)), size: catSize)
            if window.frame != target { window.setFrame(target, display: false) }
            view.setCatX(0)
        } else {
            let range = xRange
            origin.x = snap(min(max(origin.x, range.lowerBound), range.upperBound))
            origin.y = floorY
            let strip = stripFrame
            if window.frame != strip { window.setFrame(strip, display: false) }
            view.setCatX(origin.x - strip.minX)
        }
        CATransaction.commit()
    }

    // MARK: Behaviour

    /// Stops whatever the cat is doing, keeping it exactly where it currently is.
    private func leaveCurrentMode() {
        stateTimer?.invalidate()
        stateTimer = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
        if mode == .walking {
            let stripX = stripFrame.minX
            origin.x = (view.presentedCatX ?? (currentX - stripX)) + stripX
            mode = .sitting
            view.setCatX(origin.x - stripX)
        }
    }

    private func sit(for duration: CGFloat) {
        leaveCurrentMode()
        mode = .sitting
        cat.pose = .sit
        guard !isHidden else { return }
        place()
        if heartTime == nil {
            view.play(.sit, facingRight: cat.facingRight, duration: CatFrame.sitLoop)
            scheduleBlink()
        }
        scheduleNext(after: duration)
        updateTimers()
    }

    private func nap() {
        leaveCurrentMode()
        mode = .sleeping
        cat.pose = .sleep
        place()
        view.play(.sleep, facingRight: cat.facingRight, duration: CatFrame.sleepLoop)
        scheduleNext(after: .random(in: 12...28))
        updateTimers()
    }

    private func walk() {
        leaveCurrentMode()
        let range = xRange
        guard range.upperBound - range.lowerBound > 60 else {
            sit(for: 4)
            return
        }
        var target = origin.x
        for _ in 0..<8 {
            target = snap(.random(in: range))
            if abs(target - origin.x) > 90 { break }
        }
        let distance = abs(target - origin.x)
        guard distance > 1 else {
            sit(for: 2)
            return
        }
        // Mostly a relaxed stroll, sometimes a little dash.
        let speed: CGFloat = Bool.random(probability: 0.18) ? .random(in: 130...170) : .random(in: 38...62)
        let duration = Double(distance / speed)

        cat.facingRight = target > origin.x
        cat.pose = .walk
        mode = .sitting   // so place() treats this as a ground layout before the slide starts
        place()
        mode = .walking

        let stripX = stripFrame.minX
        walkFrom = origin.x
        walkTo = target
        walkStart = CACurrentMediaTime()
        walkDuration = duration
        view.play(.walk, facingRight: cat.facingRight, duration: CatFrame.walkLoopDuration(speed: speed))
        view.slide(from: walkFrom - stripX, to: walkTo - stripX, duration: duration)
        scheduleNext(after: CGFloat(duration))
        updateTimers()
    }

    private func lookAround() {
        cat.facingRight.toggle()
        sit(for: .random(in: 2...5))
    }

    private func chooseNext() {
        if notesOpen {
            sit(for: 4)
            return
        }
        let roll = CGFloat.random(in: 0...1)
        if mode == .sleeping {
            sit(for: .random(in: 1.5...3))
        } else if stayPut {
            if roll < 0.3 { nap() } else { lookAround() }
        } else if roll < 0.68 {
            walk()
        } else if roll < 0.86 {
            lookAround()
        } else {
            nap()
        }
    }

    private func scheduleNext(after seconds: CGFloat) {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(timeInterval: TimeInterval(seconds), target: self,
                                          selector: #selector(stateTimerFired), userInfo: nil, repeats: false)
    }

    @objc private func stateTimerFired() {
        stateTimer = nil
        switch mode {
        case .walking:
            // Arrived.
            origin.x = walkTo
            mode = .sitting
            sit(for: .random(in: 2.5...7))
        case .sitting, .sleeping:
            chooseNext()
        case .held, .falling:
            break
        }
    }

    private func scheduleBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(timeInterval: .random(in: 2...5.5), target: self,
                                          selector: #selector(blinkTimerFired), userInfo: nil, repeats: false)
    }

    @objc private func blinkTimerFired() {
        blinkTimer = nil
        guard mode == .sitting, heartTime == nil, !isHidden else { return }
        view.blink()
        scheduleBlink()
    }

    @objc private func screensChanged() {
        guard !isHidden, mode != .held, mode != .falling else { return }
        sit(for: 1)
    }

    // MARK: Timers

    private func updateTimers() {
        let needsTick = !isHidden && (mode == .held || mode == .falling || heartTime != nil)
        if needsTick, tickTimer == nil {
            lastTick = CACurrentMediaTime()
            tickTimer = repeatingTimer(hz: 30, #selector(tick))
        } else if !needsTick, tickTimer != nil {
            tickTimer?.invalidate()
            tickTimer = nil
        }

        if !isHidden, mouseTimer == nil {
            mouseTimer = repeatingTimer(hz: 15, #selector(pollMouse))
        } else if isHidden, mouseTimer != nil {
            mouseTimer?.invalidate()
            mouseTimer = nil
        }
    }

    private func repeatingTimer(hz: Double, _ selector: Selector) -> Timer {
        let timer = Timer(timeInterval: 1 / hz, target: self, selector: selector, userInfo: nil, repeats: true)
        timer.tolerance = 0.2 / hz
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Per-frame work for the few behaviours that are drawn live.
    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(CGFloat(now - lastTick), 0.1)
        lastTick = now
        cat.time += dt

        if mode == .falling {
            fallVelocity -= 2600 * dt
            origin.y += fallVelocity * dt
            if origin.y <= floorY {
                land()
                return
            }
            place()
        }

        if let t = heartTime {
            let next = t + dt / 1.1
            if next >= 1 {
                heartTime = nil
                if mode == .sitting {
                    sit(for: 3)
                    return
                }
            } else {
                heartTime = next
            }
        }

        drawLiveFrame()
        updateTimers()
    }

    private func drawLiveFrame() {
        cat.hearts = heartTime
        switch mode {
        case .held, .falling:
            cat.pose = .held
            cat.eyes = .wide
        default:
            cat.pose = .sit
            cat.eyes = heartTime != nil ? .happy : .open
        }
        view.show(cat)
    }

    /// Lets clicks through to whatever is underneath unless the pointer is on the cat.
    @objc private func pollMouse() {
        guard !isHidden, !view.isPressed, mode != .held else { return }
        let f = frame
        let hot = NSRect(x: f.minX + f.width * 0.1, y: f.minY, width: f.width * 0.8, height: f.height * 0.75)
        let over = hot.contains(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == over {
            window.ignoresMouseEvents = !over
            if over { NSCursor.pointingHand.set() }
        }
    }

    // MARK: Interaction

    private func pressed(at point: NSPoint) {
        let f = frame
        grabOffset = CGPoint(x: point.x - f.minX, y: point.y - f.minY)
    }

    private func clicked() {
        guard mode != .held, mode != .falling else { return }
        leaveCurrentMode()
        mode = .sitting
        cat.pose = .sit
        place()
        heartTime = 0
        lastTick = CACurrentMediaTime()
        drawLiveFrame()
        updateTimers()
        onClick?()
    }

    private func dragBegan() {
        leaveCurrentMode()
        heartTime = nil
        mode = .held
        place()
        drawLiveFrame()
        updateTimers()
    }

    private func dragMoved(to point: NSPoint) {
        guard mode == .held else { return }
        origin = CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y)
        place()
    }

    private func dragEnded() {
        guard mode == .held else { return }
        // Land on whichever screen the cat was dropped over.
        let center = CGPoint(x: origin.x + catSize.width / 2, y: origin.y + catSize.height / 2)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            screen = hit
        }
        if origin.y > floorY {
            mode = .falling
            fallVelocity = 0
            lastTick = CACurrentMediaTime()
        } else {
            land()
        }
    }

    private func land() {
        origin.y = floorY
        mode = .sitting
        sit(for: .random(in: 1.5...3))
    }

    // MARK: Debug

    /// One line describing what the cat is doing and where it is drawn.
    var debugStatus: String {
        let shown = view.presentedCatX.map { String(format: "%.1f", $0 + window.frame.minX) } ?? "?"
        return "mode=\(mode) model.x=\(String(format: "%.1f", currentX)) shown.x=\(shown) "
            + "window=\(Int(window.frame.minX)),\(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height)) "
            + "passThrough=\(window.ignoresMouseEvents) tick=\(tickTimer != nil) frame=\(view.debugPresentedFrame)"
    }

    /// Drives the same code paths as real mouse input, for the `--trace` check.
    func debugPerform(_ action: String) {
        let f = frame
        let grab = NSPoint(x: f.midX, y: f.minY + f.height * 0.3)
        switch action {
        case "click":
            pressed(at: grab)
            clicked()
        case "lift":
            pressed(at: grab)
            dragBegan()
            dragMoved(to: NSPoint(x: grab.x + 80, y: grab.y + 320))
        case "drop":
            dragEnded()
        default:
            break
        }
    }
}

private extension Bool {
    static func random(probability: Double) -> Bool { Double.random(in: 0..<1) < probability }
}
