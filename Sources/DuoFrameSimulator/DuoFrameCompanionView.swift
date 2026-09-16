//
//  DuoFrameCompanionView.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

/// Stand-in for the *other* app sharing the inner display in Split View: a plain gradient block with a faint
/// placeholder glyph, so the fold, the divider and the app's asymmetric half read correctly. Its side flips with the
/// side-controls edge, since each app keeps its controls on its outer edge.
final class DuoFrameCompanionView: UIView {

    private let gradient = CAGradientLayer()
    private let glyph = UIImageView(
        image: UIImage(systemName: "rectangle.on.rectangle")?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 34, weight: .regular))
    )
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        gradient.colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradient)

        glyph.tintColor = .white.withAlphaComponent(0.85)
        glyph.contentMode = .center
        addSubview(glyph)

        label.text = "Split View app"
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white.withAlphaComponent(0.85)
        label.textAlignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameCompanionView is created in code only")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The gradient is a raw layer, so its frame changes must skip the implicit animation the resize would trigger.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()

        glyph.sizeToFit()
        glyph.center = CGPoint(x: bounds.midX, y: bounds.midY - 14)
        label.sizeToFit()
        label.center = CGPoint(x: bounds.midX, y: glyph.frame.maxY + 14)
    }
}
#endif
