//
//  DuoFrameReservedRegionsView.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 22/09/2026.
//

#if DEBUG
import UIKit

/// A non-interactive overlay that stripes the Duo's reserved regions (the camera occlusion and the fold crease) so
/// their keep-out zones are visible without changing the framed layout. Diagonal red-on-white stripes at half opacity.
/// The fold is a static guide: the simulator can't fold, so the crease is drawn where it would land.
final class DuoFrameReservedRegionsView: UIView {

    var regions: [CGPath] = [] {
        didSet { setNeedsDisplay() }
    }

    private static let stripe: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        alpha = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameReservedRegionsView is created in code only")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !regions.isEmpty else { return }
        for region in regions {
            context.saveGState()
            context.addPath(region)
            context.clip()

            let box = region.boundingBoxOfPath
            UIColor.white.setFill()
            context.fill(box)

            // 45° stripes: each parallelogram is sheared by the box height so the edges run corner to corner.
            UIColor.red.setFill()
            var x = box.minX - box.height
            while x < box.maxX {
                let stripe = UIBezierPath()
                stripe.move(to: CGPoint(x: x, y: box.minY))
                stripe.addLine(to: CGPoint(x: x + Self.stripe, y: box.minY))
                stripe.addLine(to: CGPoint(x: x + Self.stripe + box.height, y: box.maxY))
                stripe.addLine(to: CGPoint(x: x + box.height, y: box.maxY))
                stripe.close()
                stripe.fill()
                x += Self.stripe * 2
            }
            context.restoreGState()
        }
    }
}
#endif
