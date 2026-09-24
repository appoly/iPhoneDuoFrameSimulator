//
//  DuoFrameBezel.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 23/09/2026.
//

#if DEBUG
import UIKit

/// The 27.1 simulator's device art, rebuilt as paths in the host's coordinate space. Metrics are Duo points measured
/// off the simulator's frame (captured at ≈0.9 px/pt). Each piece is laid out on canonical art, then turned to the
/// pose.
struct DuoFrameBezel: Equatable {

    enum Hardware {
        /// Closed, looking at the outer display, hinge on the left: a spine (the base half's hinge edge) shows past it.
        case outer
        /// Open in landscape: a V notch marks the fold top and bottom, buttons sit on the right half.
        case inner
        /// Any other device: a plain shell with no buttons, since there's no art to measure.
        case plain

        init?(preset: DuoFramePreset) {
            switch preset {
            case .outerLandscape, .outerPortrait: self = .outer
            case .innerLandscape, .innerPortrait, .innerSplitHalf: self = .inner
            case .otherDevice: self = .plain
            case .off: return nil
            }
        }

        var black: CGFloat {
            switch self {
            case .outer, .plain: 8.5
            case .inner: 16.5
            }
        }

        var rim: CGFloat {
            switch self {
            case .outer, .plain: 7.3
            case .inner: 3.7
            }
        }

        var buttonProtrusion: CGFloat {
            switch self {
            case .outer, .plain: 3.5
            case .inner: 2.9
            }
        }

        var hasHingeSpine: Bool {
            switch self {
            case .outer: true
            case .inner, .plain: false
            }
        }

        var hasFoldNotches: Bool {
            switch self {
            case .inner: true
            case .outer, .plain: false
            }
        }

        var hasButtons: Bool {
            switch self {
            case .outer, .inner: true
            case .plain: false
            }
        }

        func screenRadii(for geometry: DuoFrameGeometry) -> DuoFrameCornerRadii {
            switch self {
            case .outer: .forPane(preset: .outerPortrait, edge: .right, isCompanion: false)
            case .inner: DuoFrameCornerRadii(uniform: DuoFrameCornerRadii.large)
            case .plain: geometry.cornerRadii
            }
        }

        /// The body's outline around the black band: concentric, except the outer hinge edge's thinner rim and tighter
        /// corners.
        func body(around black: CGRect, radii: DuoFrameCornerRadii) -> (CGRect, DuoFrameCornerRadii) {
            var rect = black.insetBy(dx: -rim, dy: -rim)
            var bodyRadii = radii.outset(by: rim)
            if hasHingeSpine {
                rect.origin.x += rim - Outer.hingeRim
                rect.size.width -= rim - Outer.hingeRim
                bodyRadii.topLeft = Outer.hingeCornerRadius
                bodyRadii.bottomLeft = Outer.hingeCornerRadius
            }
            return (rect, bodyRadii)
        }

        /// Where the rim's shading starts across its width (0 = the inner tone at the black edge). The inner display's
        /// thin rim is almost entirely its facing tone.
        var rimShadeStart: CGFloat {
            switch self {
            case .outer, .plain: 0
            case .inner: 0.7
            }
        }
    }

    /// How the canonical art is turned to the pose, following `DuoFrameCornerRadii.forPane`: outer portrait mirrors for
    /// left-edge controls, while outer and inner landscape rotate.
    enum Orientation {
        case upright, mirrored, clockwise, anticlockwise, upsideDown

        init(geometry: DuoFrameGeometry) {
            let controlsOnRight = (geometry.sideEdge ?? .right).isRight
            switch geometry.preset {
            case .outerPortrait: self = controlsOnRight ? .upright : .mirrored
            case .outerLandscape: self = controlsOnRight ? .clockwise : .anticlockwise
            case .innerLandscape, .innerSplitHalf: self = controlsOnRight ? .upright : .upsideDown
            case .innerPortrait: self = .anticlockwise
            case .otherDevice, .off: self = .upright
            }
        }

        var isQuarterTurn: Bool {
            switch self {
            case .clockwise, .anticlockwise: true
            case .upright, .mirrored, .upsideDown: false
            }
        }

        /// Maps canonical coordinates (origin at the canonical display's top-left) onto the posed display's.
        func transform(canonical size: CGSize) -> CGAffineTransform {
            switch self {
            case .upright: .identity
            case .mirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
            case .clockwise: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
            case .anticlockwise: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
            case .upsideDown: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
            }
        }

        func orient(_ radii: DuoFrameCornerRadii) -> DuoFrameCornerRadii {
            switch self {
            case .upright:
                return radii
            case .mirrored:
                return DuoFrameCornerRadii(
                    topLeft: radii.topRight,
                    topRight: radii.topLeft,
                    bottomLeft: radii.bottomRight,
                    bottomRight: radii.bottomLeft
                )
            case .clockwise:
                return DuoFrameCornerRadii(
                    topLeft: radii.bottomLeft,
                    topRight: radii.topLeft,
                    bottomLeft: radii.bottomRight,
                    bottomRight: radii.topRight
                )
            case .anticlockwise:
                return DuoFrameCornerRadii(
                    topLeft: radii.topRight,
                    topRight: radii.bottomRight,
                    bottomLeft: radii.topLeft,
                    bottomRight: radii.bottomLeft
                )
            case .upsideDown:
                return DuoFrameCornerRadii(
                    topLeft: radii.bottomRight,
                    topRight: radii.bottomLeft,
                    bottomLeft: radii.topRight,
                    bottomRight: radii.topLeft
                )
            }
        }
    }

    /// A spine or button, shaded along its length.
    struct Part: Equatable {
        let path: CGPath
        let frame: CGRect
        var isHorizontal: Bool { frame.width > frame.height }
    }

    let hardware: Hardware
    let screen: CGPath
    /// The black band's outer edge; filled solid, since the app window covers the display area.
    let black: CGPath
    let body: CGPath
    let bodyFrame: CGRect
    /// The body's corner radii as drawn, per on-screen corner.
    let bodyRadii: DuoFrameCornerRadii
    let rimWidth: CGFloat
    /// Host points per Duo point.
    let scale: CGFloat
    let spine: Part?
    let buttons: [Part]
    /// Everything drawn, for the fit test and the caption.
    let bounds: CGRect

    private enum Outer {
        static let hingeRim: CGFloat = 5.9
        static let hingeCornerRadius: CGFloat = 4
        static let spineReach: CGFloat = 13.1
        static let spineCornerRadius: CGFloat = 10
    }

    private enum Fold {
        static let notchWidth: CGFloat = 6
        static let notchDepth: CGFloat = 2.4
    }

    /// Measured from the hinge line (the outer body's hinge edge, or the inner fold) and from the body's top edge.
    private enum Buttons {
        static let top: [ClosedRange<CGFloat>] = [224...289, 304...369]
        static let side: ClosedRange<CGFloat> = 204...315
        static let cornerRadius: CGFloat = 2.5
        static let overlap = cornerRadius * 2
    }

    /// - Parameters:
    ///   - display: the display (or split stage) in host points.
    ///   - scale: host points per Duo point.
    init?(geometry: DuoFrameGeometry, display: CGRect, scale: CGFloat) {
        guard let hardware = Hardware(preset: geometry.preset) else { return nil }
        self.hardware = hardware
        let orientation = Orientation(geometry: geometry)
        let posed = CGSize(width: display.width / scale, height: display.height / scale)
        let size = orientation.isQuarterTurn ? CGSize(width: posed.height, height: posed.width) : posed
        let screenRect = CGRect(origin: .zero, size: size)

        let screenRadii = hardware.screenRadii(for: geometry)
        let black = hardware.black
        let blackRect = screenRect.insetBy(dx: -black, dy: -black)
        let blackRadii = screenRadii.outset(by: black)
        let (bodyRect, bodyRadii) = hardware.body(around: blackRect, radii: blackRadii)

        var blackPath = blackRadii.path(in: blackRect)
        var bodyPath = bodyRadii.path(in: bodyRect)
        if hardware.hasFoldNotches {
            bodyPath = bodyPath.subtracting(Self.foldNotches(across: bodyRect, foldX: screenRect.midX))
            blackPath = blackPath.subtracting(Self.foldNotches(across: blackRect, foldX: screenRect.midX))
        }
        let spinePath = hardware.hasHingeSpine ? Self.spine(body: bodyRect, black: blackRect) : nil
        let buttonRects = hardware.hasButtons
            ? Self.buttons(hardware: hardware, body: bodyRect, screen: screenRect)
            : []

        var toHost = orientation.transform(canonical: size)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: display.minX, y: display.minY))
        func place(_ path: CGPath) -> CGPath { path.copy(using: &toHost) ?? path }
        func part(_ path: CGPath) -> Part {
            let placed = place(path)
            return Part(path: placed, frame: placed.boundingBoxOfPath)
        }

        screen = place(screenRadii.path(in: screenRect))
        self.black = place(blackPath)
        body = place(bodyPath)
        bodyFrame = bodyRect.applying(toHost)
        self.bodyRadii = orientation.orient(bodyRadii).scaled(scale)
        rimWidth = hardware.rim * scale
        self.scale = scale
        spine = spinePath.map(part)
        buttons = buttonRects.map { part(Buttons.cornerRadius.path(in: $0)) }
        bounds = ([spine?.frame].compactMap { $0 } + buttons.map(\.frame)).reduce(bodyFrame) { $0.union($1) }
    }

    /// The base half's hinge edge, showing past the closed device's hinge side and tucked under the body.
    private static func spine(body: CGRect, black: CGRect) -> CGPath {
        let rect = CGRect(
            x: body.minX - Outer.spineReach, y: black.minY,
            width: Outer.spineReach + Buttons.overlap, height: black.height
        )
        let radius = Outer.spineCornerRadius
        return DuoFrameCornerRadii(topLeft: radius, topRight: 0, bottomLeft: radius, bottomRight: 0).path(in: rect)
    }

    /// Two buttons on the top edge and one on the right, each tucked under the body.
    private static func buttons(hardware: Hardware, body: CGRect, screen: CGRect) -> [CGRect] {
        let protrusion = hardware.buttonProtrusion
        let hingeX = hardware.hasHingeSpine ? body.minX : screen.midX
        let top = Buttons.top.map { span in
            CGRect(
                x: hingeX + span.lowerBound, y: body.minY - protrusion,
                width: span.upperBound - span.lowerBound, height: protrusion + Buttons.overlap
            )
        }
        let side = CGRect(
            x: body.maxX - Buttons.overlap, y: body.minY + Buttons.side.lowerBound,
            width: protrusion + Buttons.overlap, height: Buttons.side.upperBound - Buttons.side.lowerBound
        )
        return top + [side]
    }

    /// V notches where the fold meets the top and bottom edges, overshooting the edge so the cut is clean.
    private static func foldNotches(across rect: CGRect, foldX: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let half = Fold.notchWidth / 2
        for (edge, inward) in [(rect.minY, CGFloat(1)), (rect.maxY, -1)] {
            let overshoot = edge - inward * half
            path.addLines(between: [
                CGPoint(x: foldX - half * 2, y: overshoot),
                CGPoint(x: foldX - half, y: edge),
                CGPoint(x: foldX, y: edge + inward * Fold.notchDepth),
                CGPoint(x: foldX + half, y: edge),
                CGPoint(x: foldX + half * 2, y: overshoot)
            ])
            path.closeSubpath()
        }
        return path
    }
}

private extension CGFloat {
    func path(in rect: CGRect) -> CGPath {
        DuoFrameCornerRadii(uniform: self).path(in: rect)
    }
}

private extension DuoFrameCornerRadii {
    func outset(by amount: CGFloat) -> DuoFrameCornerRadii {
        DuoFrameCornerRadii(
            topLeft: topLeft + amount, topRight: topRight + amount,
            bottomLeft: bottomLeft + amount, bottomRight: bottomRight + amount
        )
    }
}
#endif
