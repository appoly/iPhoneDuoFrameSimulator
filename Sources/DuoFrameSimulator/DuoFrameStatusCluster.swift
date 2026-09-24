//
//  DuoFrameStatusCluster.swift
//  DuoFrameSimulator
//

#if DEBUG
import UIKit

/// The Duo status cluster: clock and combined network glyph on a frosted pill, stacked in the side strip or side by
/// side in the inner display's portrait corner.
final class DuoFrameStatusCluster: UIView {

    enum Axis {
        /// The pill runs from `pillStart` down past the glyph.
        case vertical(pillStart: CGFloat)
        /// The pill wraps the clock to the glyph's left.
        case horizontal
    }

    // Measured on the 27.1 Duo simulator. Offsets are from the network ring's centre, which owners place.
    private enum Metrics {
        static let pillThickness: CGFloat = 54
        static let pillEndBeyondRing: CGFloat = 27
        static let verticalClockOffset: CGFloat = 37.3
        static let horizontalClockOffset: CGFloat = 51.4
        static let horizontalLeadPadding: CGFloat = 13.6
    }

    static let glyphSide = DuoFrameNetworkGlyph.side

    /// No public effect matches the real pill's heavy blur with a faint tint; regular glass gets the blur closest.
    private let pill: UIVisualEffectView = {
        if #available(iOS 26, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.cornerConfiguration = .capsule()
            return glass
        }
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.clipsToBounds = true
        return blur
    }()
    private let clock = UILabel()
    private let network = DuoFrameNetworkGlyph()
    private var clockTimer: Timer?
    private var colourTimer: Timer?
    private var clockPrefersDark: Bool?
    private var networkPrefersDark: Bool?
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        formatter.amSymbol = ""
        formatter.pmSymbol = ""
        return formatter
    }()

    /// The app content the glyph colours are sampled from; the cluster itself sits in the overlay window.
    weak var sampledView: UIView?

    private static let colourSampleInterval: TimeInterval = 0.12
    fileprivate static let darkForegroundLuminance: CGFloat = 0.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // Monospaced digits so the label's width is stable as the minutes change and the text never truncates.
        clock.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        clock.textColor = .label
        clock.textAlignment = .center
        for view in [pill, clock, network] {
            addSubview(view)
        }
        updateClock()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameStatusCluster is created in code only")
    }

    deinit {
        clockTimer?.invalidate()
        colourTimer?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            clockTimer?.invalidate()
            clockTimer = nil
            stopColourSampling()
            return
        }
        updateClock()
        guard clockTimer == nil else { return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
    }

    private func updateClock() {
        let time = clockFormatter.string(from: .now).trimmingCharacters(in: .whitespaces)
        guard clock.text != time else { return }
        clock.text = time
        clock.sizeToFit()
    }

    /// Lays the pill, clock and glyph out around `ring`, the glyph's centre in this view's space.
    func place(ring: CGPoint, axis: Axis) {
        network.center = ring
        let half = Metrics.pillThickness / 2
        switch axis {
        case .vertical(let pillStart):
            clock.center = CGPoint(x: ring.x, y: ring.y - Metrics.verticalClockOffset)
            pill.frame = CGRect(
                x: ring.x - half, y: pillStart,
                width: Metrics.pillThickness, height: ring.y + Metrics.pillEndBeyondRing - pillStart
            )
        case .horizontal:
            clock.center = CGPoint(x: ring.x - Metrics.horizontalClockOffset, y: ring.y)
            let start = clock.frame.minX - Metrics.horizontalLeadPadding
            pill.frame = CGRect(
                x: start, y: ring.y - half,
                width: ring.x + Metrics.pillEndBeyondRing - start, height: Metrics.pillThickness
            )
        }
        if #unavailable(iOS 26) {
            pill.layer.cornerRadius = half
        }
    }

    // MARK: - Adaptive glyph colour

    /// Turns the clock/network colour sampling on or off; disabling returns the glyphs to `.label`.
    func setColourAdaptation(_ enabled: Bool) {
        if enabled, window != nil {
            startColourSampling()
        } else {
            stopColourSampling()
        }
    }

    private func startColourSampling() {
        guard colourTimer == nil else { return }
        // In `.common` modes so it keeps firing while a finger is down and the run loop is tracking a scroll —
        // a default-mode timer pauses there, freezing the glyph colour mid-scroll.
        let timer = Timer(timeInterval: Self.colourSampleInterval, repeats: true) { [weak self] _ in
            self?.sampleStatusColours()
        }
        RunLoop.main.add(timer, forMode: .common)
        colourTimer = timer
    }

    private func stopColourSampling() {
        colourTimer?.invalidate()
        colourTimer = nil
        clockPrefersDark = nil
        networkPrefersDark = nil
        clock.textColor = .label
        network.foregroundColor = .label
    }

    /// The real status bar picks a dark or light foreground per region from the content beneath it. This samples the
    /// app content under the clock and under the network glyph separately, from one render covering both.
    private func sampleStatusColours() {
        guard window != nil, let source = sampledView else { return }
        let clockRegion = clock.convert(clock.bounds, to: source).integral
        let networkRegion = network.convert(network.bounds, to: source).integral
        let union = clockRegion.union(networkRegion).intersection(source.bounds)
        guard !union.isNull, union.width >= 1, union.height >= 1,
              let snapshot = Self.snapshot(of: source, region: union)?.cgImage else { return }

        let clockSub = clockRegion.offsetBy(dx: -union.minX, dy: -union.minY)
        let networkSub = networkRegion.offsetBy(dx: -union.minX, dy: -union.minY)
        if let colour = Self.averageColour(of: snapshot, subRect: clockSub) {
            applyClockForeground(dark: colour.duoPrefersDarkForeground)
        }
        if let colour = Self.averageColour(of: snapshot, subRect: networkSub) {
            applyNetworkForeground(dark: colour.duoPrefersDarkForeground)
        }
    }

    /// Crossfade a glyph's foreground only when the resolved black/white choice actually flips, so the fade fires on a
    /// real change rather than every sample.
    private func applyClockForeground(dark: Bool) {
        guard clockPrefersDark != dark else { return }
        clockPrefersDark = dark
        UIView.transition(with: clock, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.clock.textColor = dark ? .black : .white
        }
    }

    private func applyNetworkForeground(dark: Bool) {
        guard networkPrefersDark != dark else { return }
        networkPrefersDark = dark
        UIView.transition(with: network, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.network.foregroundColor = dark ? .black : .white
        }
    }

    /// Renders just `region` of the view's own (untransformed) hierarchy. `afterScreenUpdates: false` reuses the last
    /// rendered frame, which is cheap and fine for sampling.
    private static func snapshot(of view: UIView, region: CGRect) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: region, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    /// Averages `subRect` (in image points, scale 1) by drawing it into a single pixel and reading it back.
    private static func averageColour(of image: CGImage, subRect: CGRect) -> UIColor? {
        let pixels = subRect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 1, pixels.height >= 1, let crop = image.cropping(to: pixels) else { return nil }
        var rgba: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(
            red: CGFloat(rgba[0]) / 255, green: CGFloat(rgba[1]) / 255, blue: CGFloat(rgba[2]) / 255, alpha: 1
        )
    }
}

/// The Duo status bar's combined Wi‑Fi and cellular glyph: a ring open at the bottom, Wi‑Fi inside, and the signal
/// dots completing the ring's circle across the gap.
private final class DuoFrameNetworkGlyph: UIView {

    // Measured on the 27.1 Duo simulator (3x): the ring's ends sit 28.8° below horizontal; the dots are dimmed.
    private enum Metrics {
        static let ringRadius: CGFloat = 18.7
        static let ringWidth: CGFloat = 3.33
        static let ringEndAngle: CGFloat = 28.8 * .pi / 180
        static let dotRadius: CGFloat = 19
        static let dotDiameter: CGFloat = 4
        static let dotAngles: [CGFloat] = [58.7, 79.6, 100.4, 121.3].map { $0 * .pi / 180 }
        static let dotAlpha: CGFloat = 0.25
        static let wifiPointSize: CGFloat = 16.5
    }

    static let side: CGFloat = 44

    var foregroundColor: UIColor = .label {
        didSet {
            guard foregroundColor != oldValue else { return }
            wifi.tintColor = foregroundColor
            setNeedsDisplay()
        }
    }

    private let wifi = UIImageView(image: UIImage(
        systemName: "wifi",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: Metrics.wifiPointSize, weight: .semibold)
    ))

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        backgroundColor = .clear
        isOpaque = false
        wifi.tintColor = foregroundColor
        wifi.contentMode = .center
        addSubview(wifi)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameNetworkGlyph is created in code only")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        wifi.sizeToFit()
        wifi.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func draw(_ rect: CGRect) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let ring = UIBezierPath(
            arcCenter: centre, radius: Metrics.ringRadius,
            startAngle: .pi - Metrics.ringEndAngle, endAngle: Metrics.ringEndAngle, clockwise: true
        )
        ring.lineWidth = Metrics.ringWidth
        ring.lineCapStyle = .round
        foregroundColor.setStroke()
        ring.stroke()
        foregroundColor.withAlphaComponent(Metrics.dotAlpha).setFill()
        let dotRadius = Metrics.dotDiameter / 2
        for angle in Metrics.dotAngles {
            let dot = CGPoint(
                x: centre.x + Metrics.dotRadius * cos(angle), y: centre.y + Metrics.dotRadius * sin(angle)
            )
            UIBezierPath(ovalIn: CGRect(
                x: dot.x - dotRadius, y: dot.y - dotRadius, width: Metrics.dotDiameter, height: Metrics.dotDiameter
            )).fill()
        }
    }
}

private extension UIColor {
    /// True on a light background (wanting a black foreground), false on a dark one — from relative luminance, as the
    /// status bar picks a legible foreground for the content beneath it.
    var duoPrefersDarkForeground: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > DuoFrameStatusCluster.darkForegroundLuminance
    }
}
#endif
