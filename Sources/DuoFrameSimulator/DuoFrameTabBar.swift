//
//  DuoFrameTabBar.swift
//  DuoFrameSimulator
//

#if DEBUG
import UIKit

/// Stand-in for the inner display's portrait tab bar: a floating pill of icon-over-title items with every tab showing,
/// whatever style the host gave the real bar. Hosted in the tab bar controller's own view so presentations cover it.
final class DuoFrameTabBar: UIView {

    // Measured on the 27.1 Duo simulator: the bar owns the bottom 83 pt with its pill 21 pt up; items are 54 pt tall,
    // 86 pt apart for up to three tabs, else sharing 372 pt. Each highlight overhangs its slot by `overlap`.
    private enum Metrics {
        static let reservedHeight: CGFloat = 83
        static let bottomMargin: CGFloat = 21
        static let pillPadding: CGFloat = 4
        static let itemHeight: CGFloat = 54
        static let pillHeight: CGFloat = itemHeight + pillPadding * 2
        static let fixedPitch: CGFloat = 86
        static let fixedPitchMaxCount = 3
        static let sharedWidth: CGFloat = 372
        static let fixedPitchOverlap: CGFloat = 8
        static let sharedOverlap: CGFloat = 20
        static let symbolPointSize: CGFloat = 24
        static let imageSide: CGFloat = 28
    }

    private weak var root: UIViewController?
    private weak var tabBarController: UITabBarController?
    private var addedInset: CGFloat = 0
    private var refreshTimer: Timer?
    private var contentSignature = ""

    private let pill = UIVisualEffectView.duoFrameGlass(fallbackRadius: Metrics.pillHeight / 2)
    private let highlight = UIView()
    private var buttons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        pill.translatesAutoresizingMaskIntoConstraints = true
        highlight.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        highlight.isUserInteractionEnabled = false
        pill.contentView.addSubview(highlight)
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameTabBar is created in code only")
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Attaching

    func attach(to root: UIViewController) {
        self.root = root
        refresh()
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func detach() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        root = nil
        release()
    }

    /// SwiftUI may recreate the tab bar controller or unhide its bar on its own updates, so this polls. Like the side
    /// strip it follows the frontmost full-screen presentation; a sheet keeps the bar underneath it.
    private func refresh() {
        guard let root else { return }
        let target = root.duoFrameFrontmostFullScreen.duoFrameOnScreenContainers
            .lazy.compactMap { $0 as? UITabBarController }.first
        if target !== tabBarController {
            release()
            tabBarController = target
        }
        guard let tabBarController else { return }
        if !tabBarController.duoFrameIsTabBarHidden {
            tabBarController.duoFrameIsTabBarHidden = true
        }
        let host = tabBarController.view!
        if superview !== host {
            frame = CGRect(
                x: 0, y: host.bounds.height - Metrics.reservedHeight,
                width: host.bounds.width, height: Metrics.reservedHeight
            )
            host.addSubview(self)
        } else if host.subviews.last !== self {
            host.bringSubviewToFront(self)
        }
        reserveSafeArea(in: tabBarController)
        rebuildIfNeeded()
    }

    private func release() {
        if let tabBarController {
            tabBarController.duoFrameIsTabBarHidden = false
            tabBarController.additionalSafeAreaInsets.bottom -= addedInset
        }
        addedInset = 0
        tabBarController = nil
        contentSignature = ""
        removeFromSuperview()
    }

    /// Hiding the real bar drops its inset, so content would run under the pill; top it back up to the bar's band.
    private func reserveSafeArea(in tabBarController: UITabBarController) {
        let base = tabBarController.view.safeAreaInsets.bottom - addedInset
        let needed = max(0, Metrics.reservedHeight - base)
        guard needed != addedInset else { return }
        tabBarController.additionalSafeAreaInsets.bottom += needed - addedInset
        addedInset = needed
    }

    // MARK: - Items

    private func rebuildIfNeeded() {
        guard let tabBarController else { return }
        let items = tabBarController.tabBar.items ?? []
        let selectedIndex = tabBarController.selectedIndex
        let signature = items.map { "\(ObjectIdentifier($0).hashValue):\($0.title ?? "")" }.joined(separator: ",")
            + "|\(selectedIndex)"
        guard signature != contentSignature else { return }
        contentSignature = signature

        buttons.forEach { $0.removeFromSuperview() }
        let tint: UIColor = tabBarController.tabBar.tintColor ?? .tintColor
        buttons = items.enumerated().map { index, item in
            makeButton(item: item, index: index, selected: index == selectedIndex, tint: tint)
        }
        buttons.forEach(pill.contentView.addSubview)
        highlight.isHidden = !buttons.indices.contains(selectedIndex)
        setNeedsLayout()
    }

    private func makeButton(item: UITabBarItem, index: Int, selected: Bool, tint: UIColor) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        let image = selected ? item.selectedImage ?? item.image : item.image
        configuration.image = image.map { $0.isSymbolImage ? $0 : $0.duoFrameFitted(to: Metrics.imageSide) }
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: Metrics.symbolPointSize, weight: .medium)
        configuration.imagePlacement = .top
        configuration.imagePadding = 2
        configuration.title = item.title
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
            return attributes
        }
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = selected ? tint : .label
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = item.title
        if selected {
            button.accessibilityTraits.insert(.selected)
        }
        button.addAction(UIAction { [weak self] _ in
            self?.tabBarController?.duoFrameSelectTab(at: index)
            self?.refresh()
        }, for: .primaryActionTriggered)
        return button
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = buttons.count
        pill.isHidden = count == 0
        guard count > 0 else { return }
        let usesFixedPitch = count <= Metrics.fixedPitchMaxCount
        let pitch = usesFixedPitch ? Metrics.fixedPitch : Metrics.sharedWidth / CGFloat(count)
        let overlap = usesFixedPitch ? Metrics.fixedPitchOverlap : Metrics.sharedOverlap
        let pillWidth = CGFloat(count) * pitch + overlap + Metrics.pillPadding * 2
        pill.frame = CGRect(
            x: ((bounds.width - pillWidth) / 2).rounded(),
            y: bounds.height - Metrics.bottomMargin - Metrics.pillHeight,
            width: pillWidth, height: Metrics.pillHeight
        )
        for (index, button) in buttons.enumerated() {
            let centreX = Metrics.pillPadding + overlap / 2 + pitch * (CGFloat(index) + 0.5)
            button.frame = CGRect(
                x: centreX - (pitch + overlap) / 2, y: Metrics.pillPadding,
                width: pitch + overlap, height: Metrics.itemHeight
            )
        }
        let selectedIndex = tabBarController?.selectedIndex ?? NSNotFound
        if buttons.indices.contains(selectedIndex) {
            highlight.frame = buttons[selectedIndex].frame
            highlight.layer.cornerRadius = Metrics.itemHeight / 2
        }
    }

    /// Only the pill takes touches; the rest of the band lets the app's content underneath receive them.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }
}
#endif
