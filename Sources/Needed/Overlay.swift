import AppKit
import QuartzCore

/// The incoming-signal effect: a glow along the screen edges and emoji
/// floating up, on every display, above everything, never taking a click.
@MainActor
final class Overlay {
    private var windows: [(window: NSWindow, screen: NSScreen)] = []
    private var hide: Task<Void, Never>?

    private static let glowDuration: CFTimeInterval = 2.6
    /// How many float up per signal unless the receiver set otherwise.
    static let defaultEmojiCount = 40

    init() {
        rebuild()
        // Displays come and go: one window per screen, recreated each time.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    private func rebuild() {
        hide?.cancel()
        windows.forEach { $0.window.orderOut(nil) }
        windows = NSScreen.screens.map { ($0.window(), $0) }
    }

    /// What floats up with every signal, all mixed: hearts among hugs, cats
    /// and the rest, so it reads as warmth from anyone close, not only love.
    static let warm = [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "💖", "💕", "💗", // hearts; no 🩷 🩵: macOS 13 lacks them
        "🫂", "🤗", "🫶", "🥰", "😊", "☺️", // hugs and smiles
        "😺", "😸", "😻", "😽", "🐈", "🐱", // cats
        "🐶", "🐻", "🐼", "🦔", "🐰", "🦊", "🐥", "🧸", // more animals
        "💪", "🙌", "👍", "✊", "👏", // you've got this
        "☀️", "🌻", "🌷", "🌸", "🌼", "🌈", "🍀", "✨", "⭐️", // sun and flowers
        "☕️", "🍵", "🍪", "🍰", "🍓", "🎈", // tea and treats
    ]

    /// What the sender of a signal to anyone sees; the person who gets it
    /// sees the usual mix, as from someone close.
    static let stars = ["⭐️", "🌟", "✨", "💫"]

    /// `calm`: one soft fade instead of flashes, and nothing flies.
    func play(color: NSColor, emoji: [String], count: Int = defaultEmojiCount, calm: Bool) {
        hide?.cancel()
        var longest = Self.glowDuration
        for (window, screen) in windows {
            guard let root = window.contentView?.layer else { continue }
            window.orderFrontRegardless()
            addGlow(to: root, color: color, calm: calm)
            if !calm && !emoji.isEmpty && count > 0 {
                longest = max(longest, addEmoji(to: root, chars: emoji, count: count, scale: screen.backingScaleFactor))
            }
        }
        hide = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((longest + 0.3) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            for (window, _) in self.windows {
                window.orderOut(nil)
                window.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            }
        }
    }

    private func addGlow(to root: CALayer, color: NSColor, calm: Bool) {
        root.sublayers?.filter { $0.name == "glow" }.forEach { $0.removeFromSuperlayer() }

        let glow = CALayer()
        glow.name = "glow"
        glow.frame = root.bounds
        glow.opacity = 0

        // A soft haze fading inward from the edges, with no crisp frame line:
        // `box-shadow: inset 0 0 44px 12px color/.9`.
        let bounds = root.bounds
        let hole = bounds.insetBy(dx: 12, dy: 12)
        let ring = CGMutablePath()
        ring.addRect(bounds.insetBy(dx: -400, dy: -400))
        // The hole runs the other way round, so the non-zero rule leaves it empty.
        ring.addLines(between: [CGPoint(x: hole.minX, y: hole.minY), CGPoint(x: hole.minX, y: hole.maxY),
                                CGPoint(x: hole.maxX, y: hole.maxY), CGPoint(x: hole.maxX, y: hole.minY)])
        ring.closeSubpath()

        let haze = CALayer()
        haze.frame = bounds
        haze.shadowPath = ring
        haze.shadowColor = color.cgColor
        haze.shadowOpacity = 0.9
        haze.shadowRadius = 22 // CSS blur 44 px
        haze.shadowOffset = .zero
        glow.addSublayer(haze)

        // Three flashes in 2.6 s, about 1 Hz: well below the 3 Hz flash limit.
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        if calm {
            flash.values = [0, 0.7, 0.7, 0]
            flash.keyTimes = [0, 0.3, 0.7, 1]
        } else {
            flash.values = [0, 1, 0.25, 1, 0.25, 1, 0]
            flash.keyTimes = [0, 0.12, 0.28, 0.45, 0.61, 0.78, 1]
        }
        flash.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: flash.values!.count - 1)
        flash.duration = Self.glowDuration
        glow.add(flash, forKey: "flash")
        root.addSublayer(glow)
    }

    /// Returns when the last emoji is gone, in seconds from now.
    private func addEmoji(to root: CALayer, chars: [String], count: Int, scale: CGFloat) -> CFTimeInterval {
        let size = root.bounds.size
        let now = CACurrentMediaTime()
        var end: CFTimeInterval = 0

        for _ in 0..<count {
            let points = CGFloat.random(in: 24...46)
            let duration = Double.random(in: 3...4.6)
            let delay = Double.random(in: 0...1.3)
            end = max(end, delay + duration)

            let x = CGFloat.random(in: size.width * 0.04...size.width * 0.92)
            let rise = size.height * CGFloat.random(in: 0.45...0.9)
            let drift = CGFloat.random(in: -60...60)
            let sway = CGFloat.random(in: 14...30) * (Bool.random() ? 1 : -1)

            let layer = CATextLayer()
            layer.string = NSAttributedString(string: chars.randomElement()!,
                                              attributes: [.font: NSFont.systemFont(ofSize: points)])
            layer.alignmentMode = .center
            layer.contentsScale = scale
            layer.bounds = CGRect(x: 0, y: 0, width: points * 1.4, height: points * 1.4)
            layer.position = CGPoint(x: x, y: -points)
            layer.opacity = 0

            // Layer y grows upward: start below the bottom edge, rise on a smooth S.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: -points))
            path.addCurve(to: CGPoint(x: x + drift, y: rise),
                          control1: CGPoint(x: x + sway, y: rise * 0.35),
                          control2: CGPoint(x: x + drift - sway, y: rise * 0.7))
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.8, 1]

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.6
            grow.toValue = 1

            let tilt = CGFloat.random(in: 0.1...0.28)
            let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            wobble.values = [0, tilt, -tilt, 0]
            wobble.keyTimes = [0, 0.35, 0.65, 1]

            let group = CAAnimationGroup()
            group.animations = [move, fade, grow, wobble]
            group.duration = duration
            group.beginTime = now + delay
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.7, 0.3, 1)
            group.fillMode = .both
            group.isRemovedOnCompletion = false

            root.addSublayer(layer)
            layer.add(group, forKey: "rise")
        }
        return end
    }
}

private extension NSScreen {
    func window() -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Not in screen sharing or recordings: a glow is for the person at the screen.
        window.sharingType = .none
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view
        return window
    }
}
