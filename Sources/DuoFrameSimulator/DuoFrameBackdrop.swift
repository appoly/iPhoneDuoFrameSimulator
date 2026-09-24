//
//  DuoFrameBackdrop.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 23/09/2026.
//

#if DEBUG
import UIKit

/// Root of the non-interactive window beneath the app window: a studio-grey backdrop, the display's black glass, and
/// the device bezel wherever it fits around the frame at the frame's own scale.
final class DuoFrameBackdropViewController: UIViewController {

    private let background = CAGradientLayer()
    private let glass = CAShapeLayer()
    private let bezel = CALayer()
    private let spine = CAGradientLayer()
    private let spineMask = CAShapeLayer()
    private var buttons: [CAGradientLayer] = []
    private let rimBase = CAShapeLayer()
    private let rimClip = CAShapeLayer()
    private let rimShadeContainer = CALayer()
    private let rimShade = CAGradientLayer()
    private let rimRamp = CALayer()
    private var shown: DuoFrameBezel?

    /// 8-bit greys sampled from the simulator's device art. Light falls from above, so each edge of the rim fades from
    /// the shared inner tone to its facing tone at the outer edge.
    private enum Tone {
        static let rimInner: CGFloat = 88
        static let rimUp: CGFloat = 104
        static let rimRight: CGFloat = 74
        static let rimDown: CGFloat = 74
        static let rimLeft: CGFloat = 90
        static let spine = EndShading(middle: 68, start: 77, startLength: 5, end: 59, endLength: 6)
        static let horizontalButton = EndShading(middle: 89, start: 89, startLength: 0, end: 73, endLength: 6.5)
        static let verticalButton = EndShading(middle: 89, start: 104, startLength: 5, end: 71, endLength: 7)
    }

    /// A flat tone that catches the light at its top or left end and rolls off at the other; lengths in Duo points.
    private struct EndShading {
        let middle: CGFloat
        let start: CGFloat
        let startLength: CGFloat
        let end: CGFloat
        let endLength: CGFloat
    }

    private static let rampSteps = 6

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        background.type = .radial
        background.startPoint = CGPoint(x: 0.5, y: 0.5)
        background.endPoint = CGPoint(x: 1, y: 1)
        view.layer.addSublayer(background)

        spine.mask = spineMask
        bezel.addSublayer(spine)
        rimBase.fillColor = Self.grey(Tone.rimInner)
        bezel.addSublayer(rimBase)
        rimShade.type = .conic
        rimShade.mask = rimRamp
        rimShadeContainer.mask = rimClip
        rimShadeContainer.addSublayer(rimShade)
        bezel.addSublayer(rimShadeContainer)
        view.layer.addSublayer(bezel)

        glass.fillColor = UIColor.black.cgColor
        view.layer.addSublayer(glass)
        clear()

        updateBackgroundColours()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateBackgroundColours()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        withoutAnimation { background.frame = view.bounds }
    }

    func clear() {
        withoutAnimation {
            glass.isHidden = true
            bezel.isHidden = true
        }
        shown = nil
    }

    /// Draws the glass for `display`, and the bezel too when it fits inside `arena`; the frame is never shrunk to make
    /// room for it. Returns the bezel's on-screen extent, or `nil` when only the glass is drawn.
    func show(geometry: DuoFrameGeometry, display: CGRect, scale: CGFloat, arena: CGRect) -> CGRect? {
        loadViewIfNeeded()
        guard let bezel = DuoFrameBezel(geometry: geometry, display: display, scale: scale) else {
            clear()
            return nil
        }
        let fits = arena.contains(bezel.bounds)
        withoutAnimation {
            glass.isHidden = false
            glass.path = fits ? bezel.black : bezel.screen
            self.bezel.isHidden = !fits
            if fits, bezel != shown { layOut(bezel) }
        }
        shown = fits ? bezel : nil
        return fits ? bezel.bounds : nil
    }

    private func layOut(_ bezel: DuoFrameBezel) {
        if let part = bezel.spine {
            spine.isHidden = false
            fill(spine, mask: spineMask, with: part, shading: Tone.spine, scale: bezel.scale)
        } else {
            spine.isHidden = true
        }

        while buttons.count < bezel.buttons.count {
            let layer = CAGradientLayer()
            layer.mask = CAShapeLayer()
            self.bezel.insertSublayer(layer, below: rimBase)
            buttons.append(layer)
        }
        for (index, layer) in buttons.enumerated() {
            guard index < bezel.buttons.count, let mask = layer.mask as? CAShapeLayer else {
                layer.isHidden = true
                continue
            }
            let part = bezel.buttons[index]
            layer.isHidden = false
            let shading = part.isHorizontal ? Tone.horizontalButton : Tone.verticalButton
            fill(layer, mask: mask, with: part, shading: shading, scale: bezel.scale)
        }

        rimBase.path = bezel.body
        rimClip.path = bezel.body
        rimShadeContainer.frame = view.bounds
        rimClip.frame = view.bounds
        layOutRimShade(bezel)
    }

    /// A conic gradient around the body's centre gives each edge its facing tone, blending through the corners; a ramp
    /// of nested strokes then fades it in from the rim's inner edge.
    private func layOutRimShade(_ bezel: DuoFrameBezel) {
        let body = bezel.bodyFrame
        // Square, so the conic's angles are true angles rather than stretched by the layer's aspect ratio.
        let side = max(body.width, body.height)
        rimShade.frame = CGRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side)
        rimShade.startPoint = CGPoint(x: 0.5, y: 0.5)
        rimShade.endPoint = CGPoint(x: 0.5, y: 0)

        let halfWidth = body.width / 2
        let halfHeight = body.height / 2
        let radii = bezel.bodyRadii
        // Clockwise angles from straight up, as fractions of a turn, where each corner's curve begins and ends.
        func turn(_ across: CGFloat, _ along: CGFloat) -> CGFloat { atan2(across, along) / (2 * .pi) }
        let stops: [(CGFloat, CGFloat)] = [
            (0, Tone.rimUp),
            (turn(halfWidth - radii.topRight, halfHeight), Tone.rimUp),
            (turn(halfWidth, halfHeight - radii.topRight), Tone.rimRight),
            (0.5 - turn(halfWidth, halfHeight - radii.bottomRight), Tone.rimRight),
            (0.5 - turn(halfWidth - radii.bottomRight, halfHeight), Tone.rimDown),
            (0.5 + turn(halfWidth - radii.bottomLeft, halfHeight), Tone.rimDown),
            (0.5 + turn(halfWidth, halfHeight - radii.bottomLeft), Tone.rimLeft),
            (1 - turn(halfWidth, halfHeight - radii.topLeft), Tone.rimLeft),
            (1 - turn(halfWidth - radii.topLeft, halfHeight), Tone.rimUp),
            (1, Tone.rimUp)
        ]
        rimShade.colors = stops.map { Self.grey($0.1) }
        rimShade.locations = stops.map { NSNumber(value: Double($0.0)) }

        rimRamp.frame = rimShade.bounds
        rimRamp.sublayers?.forEach { $0.removeFromSuperlayer() }
        var toRamp = CGAffineTransform(translationX: -rimShade.frame.minX, y: -rimShade.frame.minY)
        let outline = bezel.body.copy(using: &toRamp)
        // Stroke k (widest first) brings the covered alpha to its share of the ramp; alphas composite, so each stroke
        // only adds what the strokes outside it haven't already covered.
        let steps = Self.rampSteps
        let start = bezel.hardware.rimShadeStart
        var covered: CGFloat = 0
        for step in (1...steps).reversed() {
            let target = start + (1 - start) * CGFloat(steps - step) / CGFloat(steps - 1)
            let stroke = CAShapeLayer()
            stroke.path = outline
            stroke.fillColor = nil
            stroke.strokeColor = UIColor.black.cgColor
            stroke.lineWidth = 2 * bezel.rimWidth * CGFloat(step) / CGFloat(steps)
            stroke.opacity = Float((target - covered) / (1 - covered))
            rimRamp.addSublayer(stroke)
            covered = target
        }
    }

    private func fill(
        _ layer: CAGradientLayer, mask: CAShapeLayer, with part: DuoFrameBezel.Part, shading: EndShading, scale: CGFloat
    ) {
        layer.frame = part.frame
        let length = max(part.frame.width, part.frame.height)
        layer.colors = [shading.start, shading.middle, shading.middle, shading.end].map(Self.grey)
        layer.locations = [0, shading.startLength * scale / length, 1 - shading.endLength * scale / length, 1]
            .map { NSNumber(value: Double($0)) }
        layer.startPoint = part.isHorizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        layer.endPoint = part.isHorizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        var toLayer = CGAffineTransform(translationX: -part.frame.minX, y: -part.frame.minY)
        mask.frame = layer.bounds
        mask.path = part.path.copy(using: &toLayer)
    }

    private func updateBackgroundColours() {
        let (centre, edge): (CGFloat, CGFloat)
        switch traitCollection.userInterfaceStyle {
        case .dark: (centre, edge) = (58, 22)
        case .light, .unspecified: (centre, edge) = (245, 212)
        @unknown default: (centre, edge) = (245, 212)
        }
        withoutAnimation { background.colors = [Self.grey(centre), Self.grey(edge)] }
    }

    private static func grey(_ level: CGFloat) -> CGColor {
        let value = level / 255
        return UIColor(red: value, green: value, blue: value, alpha: 1).cgColor
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
#endif
