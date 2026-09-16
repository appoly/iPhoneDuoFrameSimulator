//
//  DuoFrameCorners.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import SwiftUI

/// Per-corner radii for a pane, in the Duo's own point space, drawn as continuous corners like the hardware. Corners
/// against the physical device's outer corners round more; corners along a fold seam or hinge round less. The exact
/// radii are unpublished, so these are placeholders — only the asymmetry is meant to be faithful.
struct DuoFrameCornerRadii: Equatable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    /// Extrapolated from the camera cutout: the exterior corner's curve appears to run out level with the cutout's
    /// bottom edge, 66 pt (28 inset + 38 diameter) along the edge. A continuous corner straightens out about 1.53
    /// radii along each edge, so the radius is 66 / 1.53.
    static let large: CGFloat = 43
    static let small: CGFloat = 8
    /// The outer display's hinge edge is a hard fold, so its corners are nearly square — squarer than the blended
    /// seam of an inner Split View pane.
    static let outerHinge: CGFloat = 6

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

    /// A rounded-rect path honouring all four radii independently, drawn with the system's continuous corner curve
    /// (the hardware shape) rather than circular arcs. Leading is left: the path is built outside any layout
    /// direction, so it is never mirrored.
    func path(in rect: CGRect) -> CGPath {
        let radii = RectangleCornerRadii(
            topLeading: topLeft, bottomLeading: bottomLeft, bottomTrailing: bottomRight, topTrailing: topRight
        )
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect).cgPath
    }

    /// Per-edge roundedness (0…1) for a pane, then the four corners blended from it.
    /// - `edge`: the app's side-controls edge (which physical side its controls sit on).
    /// - `isCompanion`: the placeholder pane opposite the app in Split View, whose seam faces the app.
    static func forPane(preset: DuoFramePreset, edge: DuoFrameSideEdge?, isCompanion: Bool) -> DuoFrameCornerRadii {
        let controlsOnRight = (edge ?? .right).isRight

        // Corners follow the fixed physical screen shape: the hinge edge reads squarer, every free edge rounds full.
        // The camera and controls don't affect them. Reference: closed portrait folds along the left edge; rotating
        // the device places that hinge on a different screen edge in each pose.
        switch preset {
        case .innerLandscape, .innerPortrait, .otherDevice, .off:
            return DuoFrameCornerRadii(uniform: large)   // a whole inner display (or an arbitrary size)
        case .innerSplitHalf:
            // The seam is the pane's inner edge: opposite the app's controls, and the mirror of that for the companion.
            // It reads as a softly-blended corner, not a hard hinge.
            let seamOnRight = isCompanion ? controlsOnRight : !controlsOnRight
            let (left, right): (CGFloat, CGFloat) = seamOnRight ? (1, 0) : (0, 1)
            return DuoFrameCornerRadii(
                topLeft: blend(1, left), topRight: blend(1, right),
                bottomLeft: blend(1, left), bottomRight: blend(1, right)
            )
        case .outerLandscape:
            // Landscape is the portrait device rotated: controls-right is 90° clockwise (the left-edge hinge lands on
            // top), controls-left is 90° anticlockwise (the hinge lands on the bottom).
            return controlsOnRight ? outer(hinge: .top) : outer(hinge: .bottom)
        case .outerPortrait:
            // Closed portrait folds along the edge opposite the controls (the controls sit by the camera).
            return controlsOnRight ? outer(hinge: .left) : outer(hinge: .right)
        }
    }

    private enum Edge { case top, bottom, left, right }

    /// The outer display: a hard, near-square hinge edge and three fully-rounded physical edges.
    private static func outer(hinge: Edge) -> DuoFrameCornerRadii {
        switch hinge {
        case .top:
            DuoFrameCornerRadii(topLeft: outerHinge, topRight: outerHinge, bottomLeft: large, bottomRight: large)
        case .bottom:
            DuoFrameCornerRadii(topLeft: large, topRight: large, bottomLeft: outerHinge, bottomRight: outerHinge)
        case .left:
            DuoFrameCornerRadii(topLeft: outerHinge, topRight: large, bottomLeft: outerHinge, bottomRight: large)
        case .right:
            DuoFrameCornerRadii(topLeft: large, topRight: outerHinge, bottomLeft: large, bottomRight: outerHinge)
        }
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
