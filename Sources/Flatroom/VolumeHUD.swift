import AppKit

/// Volume indicator copying the one macOS 27 shows: a clear glass capsule under the menu bar with
/// a white speaker icon and a bar of 16 segments, shown for a moment on each change. (The private
/// OSD.framework still exists but only draws the pre-Big Sur square HUD, so we draw our own.)
final class VolumeHUD {
    private static let size = NSSize(width: 310, height: 66)

    private let panel: NSPanel
    private let icon = NSImageView()
    private let bar = SegmentBar()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        icon.frame = NSRect(x: 18, y: 12, width: 46, height: 42)
        icon.imageAlignment = .alignLeft
        icon.symbolConfiguration = .init(pointSize: 31, weight: .regular)
        icon.contentTintColor = .white
        content.addSubview(icon)
        bar.frame = NSRect(x: 70, y: 25, width: Self.size.width - 70 - 30, height: 16)
        content.addSubview(bar)
        for view in [icon, bar] as [NSView] {
            view.shadow = {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
                shadow.shadowBlurRadius = 3
                return shadow
            }()
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .clear
            glass.cornerRadius = Self.size.height / 2
            glass.contentView = content
            panel.contentView = glass
            Self.matchSystemHUD(glass, content: content)
        } else {
            let blur = NSVisualEffectView(frame: content.frame)
            blur.material = .hudWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.size.height / 2
            blur.addSubview(content)
            panel.contentView = blur
        }
    }

    func show(volume: Float, muted: Bool) {
        let level = muted ? 0 : volume
        let symbol: String
        switch level {
        case 0: symbol = "speaker.slash.fill"
        case ..<0.34: symbol = "speaker.wave.1.fill"
        case ..<0.67: symbol = "speaker.wave.2.fill"
        default: symbol = "speaker.wave.3.fill"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Volume")
        bar.level = CGFloat(level)

        // Just under the menu bar, centred on the Sound menu extra like macOS does (top right if it's hidden).
        let anchor = Self.soundExtraMidX()
        if let screen = anchor.flatMap({ x in NSScreen.screens.first { $0.frame.minX <= x && x < $0.frame.maxX } })
            ?? NSScreen.main {
            let frame = screen.visibleFrame
            let x = anchor.map { min(max($0 - Self.size.width / 2, frame.minX + 8), frame.maxX - Self.size.width - 8) }
                ?? frame.maxX - Self.size.width - 12
            panel.setFrameOrigin(NSPoint(x: x, y: frame.maxY - Self.size.height - 6))
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; self?.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Public `.clear` glass still blurs what's behind it; the system HUD is a sharp lens that only
    /// refracts at the rim. That look is the private glass variant 11 with scrim state 2 (found by
    /// trying them side by side). Guarded so a future AppKit without these keys just keeps `.clear`.
    /// Bright backgrounds are then capped at the grey the system HUD shows over white (253 → 196,
    /// measured from a recording) with a darken blend, which leaves darker colours untouched.
    @available(macOS 26.0, *)
    private static func matchSystemHUD(_ glass: NSGlassEffectView, content: NSView) {
        for (key, value) in [("_variant", 11), ("_scrimState", 2)]
        where glass.responds(to: NSSelectorFromString("set\(key):")) {
            glass.setValue(value, forKey: key)
        }
        content.wantsLayer = true
        let dim = CALayer()
        dim.frame = content.bounds
        dim.cornerRadius = size.height / 2
        dim.backgroundColor = NSColor(white: 196 / 255, alpha: 1).cgColor
        dim.compositingFilter = "darkenBlendMode"
        content.layer?.insertSublayer(dim, at: 0)
    }

    /// Horizontal centre of the Sound icon in the menu bar, read through Accessibility from the
    /// process that hosts the system menu extras (MenuBarAgent on macOS 27).
    private static func soundExtraMidX() -> CGFloat? {
        let names: Set<String> = ["Sonido", "Sound", "Son", "Ton", "Suono", "Som", "Geluid"]
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent") {
            guard let bar = attribute(AXUIElementCreateApplication(app.processIdentifier), "AXExtrasMenuBar") else { continue }
            for extra in attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                let items = [extra] + (attribute(extra, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                guard items.contains(where: { names.contains(attribute($0, kAXDescriptionAttribute) as? String ?? "") }),
                      let position = attribute(extra, kAXPositionAttribute), let size = attribute(extra, kAXSizeAttribute)
                else { continue }
                var origin = CGPoint.zero, extent = CGSize.zero
                AXValueGetValue(position as! AXValue, .cgPoint, &origin)
                AXValueGetValue(size as! AXValue, .cgSize, &extent)
                return origin.x + extent.width / 2
            }
        }
        return nil
    }
}

/// Row of 16 rounded dashes, one per volume key step: lit ones in solid white, the rest dimmed.
/// A fine (Option+Shift) step lights part of a dash.
private final class SegmentBar: NSView {
    private static let segments = 16
    private static let gap: CGFloat = 2.5
    private static let thickness: CGFloat = 3

    var level: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = CGFloat(Self.segments)
        let width = (bounds.width - Self.gap * (count - 1)) / count
        let y = bounds.midY - Self.thickness / 2
        let lit = min(max(level, 0), 1) * count
        let radius = Self.thickness / 2

        for i in 0..<Self.segments {
            let rect = NSRect(x: CGFloat(i) * (width + Self.gap), y: y, width: width, height: Self.thickness)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

            let fill = min(max(lit - CGFloat(i), 0), 1)
            if fill > 0 {
                var litRect = rect
                litRect.size.width *= fill
                NSColor.white.setFill()
                NSBezierPath(roundedRect: litRect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }
}
