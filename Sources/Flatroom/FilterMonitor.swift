import AppKit
import AudioEngine

/// Window showing the correction at work: the spectrum going into the filter and coming out of it,
/// and the difference between the two (what the filter is doing to this music) next to the filter's
/// own response. The audio thread only copies samples while the window is open.
final class FilterMonitor: NSObject, NSWindowDelegate {
    private let controller: CorrectionController
    private let statusText: () -> String
    private var window: NSWindow?
    private let plot = SpectrumPlotView()
    private let status = NSTextField(labelWithString: "")
    private let bypassBox = NSButton(checkboxWithTitle: "Bypass (compare without correction)", target: nil, action: nil)
    private var timer: Timer?
    private var engine: ConvolutionEngine?
    private var analyzer: SpectrumAnalyzer?

    init(controller: CorrectionController, statusText: @escaping () -> String) {
        self.controller = controller
        self.statusText = statusText
        super.init()
        bypassBox.target = self
        bypassBox.action = #selector(toggleBypass)
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        engine?.probe.isEnabled = false
        engine = nil
        analyzer = nil
    }

    @objc private func toggleBypass() {
        controller.bypass = bypassBox.state == .on
        controller.onChange?()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Filter in Action"
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("FilterMonitor")
        if window.frame.origin == .zero { window.center() }

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        bypassBox.controlSize = .small
        bypassBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let content = NSView()
        for view in [status, bypassBox, plot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: bypassBox.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: bypassBox.leadingAnchor, constant: -12),
            bypassBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bypassBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            plot.topAnchor.constraint(equalTo: bypassBox.bottomAnchor, constant: 8),
            plot.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            plot.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            plot.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        window.contentView = content
        return window
    }

    private func tick() {
        let filterName = controller.activeFilter.map { " · \($0)" } ?? ""
        status.stringValue = statusText() + filterName
        bypassBox.state = controller.bypass ? .on : .off
        bypassBox.isEnabled = controller.isRunning

        // The engine changes whenever the tap restarts (new device, rate or filter).
        if controller.engine !== engine {
            engine?.probe.isEnabled = false
            engine = controller.engine
            analyzer = nil
            if let engine {
                let analyzer = SpectrumAnalyzer(sampleRate: engine.filter.sampleRate)
                self.analyzer = analyzer
                plot.frequencies = analyzer.frequencies
                plot.targets = engine.filter.channels.prefix(2).map {
                    SpectrumAnalyzer.magnitudeResponse($0, sampleRate: engine.filter.sampleRate, at: analyzer.frequencies)
                }
                plot.reset()
                engine.probe.isEnabled = true
            }
        }

        guard let engine, let analyzer, controller.isRunning else {
            plot.message = controller.isRunning ? "Running without a filter for this sample rate"
                                                : "Correction isn't running"
            plot.needsDisplay = true
            return
        }
        analyzer.update(from: engine.probe)
        plot.message = nil
        plot.bypassed = controller.bypass
        plot.hasSignal = analyzer.hasSignal
        plot.input = analyzer.inputDB
        plot.output = analyzer.outputDB
        plot.correction = analyzer.correctionDB
        plot.needsDisplay = true
    }
}

/// Two log-frequency plots: input vs output spectrum, and applied correction vs filter response.
final class SpectrumPlotView: NSView {
    var frequencies: [Double] = []
    var input: [Float] = []
    var output: [Float] = []
    var correction: [Float?] = []
    /// Filter response per channel (L, R).
    var targets: [[Float]] = [] {
        didSet { correctionRange = Self.range(for: targets.flatMap { $0 }) }
    }
    var message: String?
    var bypassed = false
    var hasSignal = false

    private var spectrumTop: Float = -10
    private var correctionRange: (lo: Float, hi: Float) = (-12, 12)
    private static let spectrumSpan: Float = 60
    private static let dashL: [CGFloat] = [5, 3]
    private static let dashR: [CGFloat] = [1.5, 2.5]
    private static let ticks: [(Double, String)] = [
        (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k"),
    ]

    override var isFlipped: Bool { true }

    func reset() {
        input = []
        output = []
        correction = []
        spectrumTop = -10
    }

    private static func range(for values: [Float]) -> (lo: Float, hi: Float) {
        guard let lo = values.min(), let hi = values.max() else { return (-12, 12) }
        let mid = (lo + hi) / 2
        let half = max((hi - lo) / 2 + 3, 9)
        return ((((mid - half) / 3).rounded(.down)) * 3, (((mid + half) / 3).rounded(.up)) * 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        if let message {
            drawCentered(message, in: bounds)
            return
        }
        guard frequencies.count > 1 else { return }

        // Follow the music's level slowly so the curves stay in view without jumping.
        if let loudest = (input + output).max(), loudest > -150 {
            let target = min(20, ((loudest + 6) / 10).rounded(.up) * 10)
            spectrumTop += (target - spectrumTop) * (target > spectrumTop ? 0.3 : 0.02)
        }

        let margin = NSEdgeInsets(top: 28, left: 52, bottom: 30, right: 20)
        let gap: CGFloat = 52
        let usable = bounds.height - margin.top - margin.bottom - gap
        let topPanel = NSRect(x: margin.left, y: margin.top, width: bounds.width - margin.left - margin.right,
                              height: usable * 0.55)
        let bottomPanel = NSRect(x: margin.left, y: topPanel.maxY + gap, width: topPanel.width,
                                 height: usable * 0.45)

        // Spectrum: before and after the filter.
        let top = spectrumTop, bottom = spectrumTop - Self.spectrumSpan
        drawGrid(in: topPanel, lo: bottom, hi: top, step: 10, unit: "dB")
        drawCurve(input.map(Optional.some), in: topPanel, lo: bottom, hi: top,
                  color: .secondaryLabelColor, width: 1.2)
        drawCurve(output.map(Optional.some), in: topPanel, lo: bottom, hi: top,
                  color: .controlAccentColor, width: 1.8, fill: true)
        drawTitle("Spectrum", in: topPanel)
        drawLegend([("Before the filter", .secondaryLabelColor, nil),
                    (bypassed ? "Output (bypass)" : "After the filter", .controlAccentColor, nil)], in: topPanel)
        if !hasSignal { drawCentered("No audio playing", in: topPanel) }

        // Correction: what the filter does to this audio vs what it is designed to do.
        let (lo, hi) = correctionRange
        drawGrid(in: bottomPanel, lo: lo, hi: hi, step: Self.niceStep(hi - lo), unit: "dB", zero: true)
        for (index, target) in targets.enumerated() {
            drawCurve(target.map(Optional.some), in: bottomPanel, lo: lo, hi: hi,
                      color: NSColor.labelColor.withAlphaComponent(0.45), width: 1, dash: index == 0 ? Self.dashL : Self.dashR)
        }
        drawCurve(correction, in: bottomPanel, lo: lo, hi: hi, color: .systemOrange, width: 2)
        drawTitle("Correction applied", in: bottomPanel)
        let targetColor = NSColor.labelColor.withAlphaComponent(0.6)
        var legend: [(String, NSColor, [CGFloat]?)] = [("Live (output ÷ input)", .systemOrange, nil)]
        if targets.count > 1 {
            legend += [("Filter L", targetColor, Self.dashL), ("Filter R", targetColor, Self.dashR)]
        } else if !targets.isEmpty {
            legend.append(("Filter", targetColor, Self.dashL))
        }
        drawLegend(legend, in: bottomPanel)
        if correction.allSatisfy({ $0 == nil }) {
            drawCentered("Play something to see the correction", in: bottomPanel)
        }
    }

    // MARK: Drawing helpers

    private func x(_ frequency: Double, in rect: NSRect) -> CGFloat {
        let lo = log(frequencies.first!), hi = log(frequencies.last!)
        return rect.minX + CGFloat((log(frequency) - lo) / (hi - lo)) * rect.width
    }

    private func y(_ db: Float, in rect: NSRect, lo: Float, hi: Float) -> CGFloat {
        rect.maxY - CGFloat((db - lo) / (hi - lo)) * rect.height
    }

    private static func niceStep(_ span: Float) -> Float {
        [1, 2, 3, 6, 10, 20].first { span / $0 <= 8 } ?? 30
    }

    private func drawGrid(in rect: NSRect, lo: Float, hi: Float, step: Float, unit: String, zero: Bool = false) {
        let grid = NSColor.separatorColor
        let labels: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        let path = NSBezierPath()
        for (frequency, label) in Self.ticks where frequency >= frequencies.first! && frequency <= frequencies.last! * 1.001 {
            let px = x(frequency, in: rect).rounded() + 0.5
            path.move(to: NSPoint(x: px, y: rect.minY))
            path.line(to: NSPoint(x: px, y: rect.maxY))
            let text = NSAttributedString(string: label, attributes: labels)
            text.draw(at: NSPoint(x: px - text.size().width / 2, y: rect.maxY + 4))
        }
        var level = (lo / step).rounded(.up) * step
        while level <= hi + 0.001 {
            let py = y(level, in: rect, lo: lo, hi: hi).rounded() + 0.5
            path.move(to: NSPoint(x: rect.minX, y: py))
            path.line(to: NSPoint(x: rect.maxX, y: py))
            let text = NSAttributedString(string: String(format: "%+.0f", level), attributes: labels)
            text.draw(at: NSPoint(x: rect.minX - text.size().width - 6, y: py - text.size().height / 2))
            level += step
        }
        grid.setStroke()
        path.lineWidth = 1
        path.stroke()

        if zero, lo < 0, hi > 0 {
            let py = y(0, in: rect, lo: lo, hi: hi).rounded() + 0.5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: py))
            line.line(to: NSPoint(x: rect.maxX, y: py))
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
            line.stroke()
        }
        let unitText = NSAttributedString(string: unit, attributes: labels)
        unitText.draw(at: NSPoint(x: rect.minX - unitText.size().width - 6, y: rect.minY - unitText.size().height - 10))
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    /// A curve with gaps where a value is nil, clipped to the panel.
    private func drawCurve(_ values: [Float?], in rect: NSRect, lo: Float, hi: Float, color: NSColor,
                           width: CGFloat, dash: [CGFloat]? = nil, fill: Bool = false) {
        guard values.count == frequencies.count else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()

        let path = NSBezierPath()
        var segments: [(first: NSPoint, last: NSPoint)] = []
        var drawing = false
        for (index, value) in values.enumerated() {
            guard let value else { drawing = false; continue }
            let point = NSPoint(x: x(frequencies[index], in: rect), y: y(value, in: rect, lo: lo, hi: hi))
            if drawing {
                path.line(to: point)
                segments[segments.count - 1].last = point
            } else {
                path.move(to: point)
                segments.append((point, point))
                drawing = true
            }
        }
        if fill, segments.count == 1, let segment = segments.first {
            let area = path.copy() as! NSBezierPath
            area.line(to: NSPoint(x: segment.last.x, y: rect.maxY))
            area.line(to: NSPoint(x: segment.first.x, y: rect.maxY))
            area.close()
            color.withAlphaComponent(0.12).setFill()
            area.fill()
        }
        path.lineWidth = width
        path.lineJoinStyle = .round
        if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    private func drawTitle(_ title: String, in rect: NSRect) {
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        text.draw(at: NSPoint(x: rect.minX, y: rect.minY - text.size().height - 6))
    }

    private func drawLegend(_ entries: [(String, NSColor, [CGFloat]?)], in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var right = rect.maxX
        for (label, color, dash) in entries.reversed() {
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let textX = right - size.width
            let textY = rect.minY - size.height - 6
            text.draw(at: NSPoint(x: textX, y: textY))
            let swatch = NSBezierPath()
            swatch.move(to: NSPoint(x: textX - 22, y: textY + size.height / 2))
            swatch.line(to: NSPoint(x: textX - 6, y: textY + size.height / 2))
            swatch.lineWidth = dash == nil ? 2 : 1.5
            if let dash { swatch.setLineDash(dash, count: dash.count, phase: 0) }
            color.setStroke()
            swatch.stroke()
            right = textX - 36
        }
    }

    private func drawCentered(_ message: String, in rect: NSRect) {
        let text = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
