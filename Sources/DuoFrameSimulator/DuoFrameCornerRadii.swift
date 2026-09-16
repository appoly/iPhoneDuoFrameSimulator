//
//  DuoFrameCorners.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

/// Per-corner radii for a pane, in the Duo's own point space. Corners against the physical device's outer corners
/// round more; corners along a fold seam or hinge round less. The exact radii are unpublished, so these are
/// placeholders — only the asymmetry is meant to be faithful.
struct DuoFrameCornerRadii: Equatable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    static let large: CGFloat = 46
    static let small: CGFloat = 8

    /// Blends each corner from the roundedness of the two edges meeting there (0 = seam/hinge, 1 = device exterior).
    private static func blend(_ edgeA: CGFloat, _ edgeB: CGFloat) -> CGFloat {
        small + (edgeA + edgeB) / 2 * (large - small)
    }

    func scaled(_ scale: CGFloat) -> DuoFrameCornerRadii {
        DuoFrameCornerRadii(
            topLeft: topLeft * scale, topRight: topRight * scale,
            bottomLeft: bottomLeft * scale, bottomRight: bottomRight * scale
        )
    }

    /// A rounded-rect path honouring all four radii independently. Circular arcs; each radius is clamped to the rect.
    func path(in rect: CGRect) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let radTL = min(topLeft, limit)
        let radTR = min(topRight, limit)
        let radBL = min(bottomLeft, limit)
        let radBR = min(bottomRight, limit)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX + radTL, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radTR, y: rect.minY))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - radTR, y: rect.minY + radTR), radius: radTR,
            startAngle: -.pi / 2, endAngle: 0, clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radBR))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - radBR, y: rect.maxY - radBR), radius: radBR,
            startAngle: 0, endAngle: .pi / 2, clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX + radBL, y: rect.maxY))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + radBL, y: rect.maxY - radBL), radius: radBL,
            startAngle: .pi / 2, endAngle: .pi, clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radTL))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + radTL, y: rect.minY + radTL), radius: radTL,
            startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: true
        )
        path.close()
        return path.cgPath
    }

    /// Per-edge roundedness (0…1) for a pane, then the four corners blended from it.
    /// - `edge`: the app's side-controls edge (which physical side its controls sit on).
    /// - `isCompanion`: the placeholder pane opposite the app in Split View, whose seam faces the app.
    static func forPane(preset: DuoFramePreset, edge: DuoFrameSideEdge?, isCompanion: Bool) -> DuoFrameCornerRadii {
        let controlsOnRight = (edge ?? .right).isRight
        var top: CGFloat = 1, bottom: CGFloat = 1, left: CGFloat = 1, right: CGFloat = 1

        // Corners follow the fixed physical screen shape: the hinge edge reads squarer, every free edge rounds full.
        // The camera and controls don't affect them. Reference: closed portrait folds along the left edge; rotating
        // the device places that hinge on a different screen edge in each pose.
        switch preset {
        case .innerLandscape, .innerPortrait, .otherDevice, .off:
            break   // a whole inner display (or an arbitrary size): every corner is a device corner
        case .innerSplitHalf:
            // The seam is the pane's inner edge: opposite the app's controls, and the mirror of that for the companion.
            let seamOnRight = isCompanion ? controlsOnRight : !controlsOnRight
            if seamOnRight { right = 0 } else { left = 0 }
        case .outerLandscape:
            // Landscape is the portrait device rotated: controls-right is 90° clockwise (the left-edge hinge lands on
            // top), controls-left is 90° anticlockwise (the hinge lands on the bottom).
            if controlsOnRight { top = 0 } else { bottom = 0 }
        case .outerPortrait:
            // Closed portrait folds along the edge opposite the controls (the controls sit by the camera).
            if controlsOnRight { left = 0 } else { right = 0 }
        }

        return DuoFrameCornerRadii(
            topLeft: blend(top, left), topRight: blend(top, right),
            bottomLeft: blend(bottom, left), bottomRight: blend(bottom, right)
        )
    }
}

extension DuoFrameCornerRadii {
    /// The same radius on all four corners — a plain device shell with no hinge or seam. Kept in an extension so the
    /// memberwise initialiser stays available.
    init(uniform radius: CGFloat) {
        self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }
}
#endif
