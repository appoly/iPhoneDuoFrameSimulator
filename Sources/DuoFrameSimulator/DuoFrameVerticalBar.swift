//
//  DuoFrameVerticalBar.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

/// Stand-in for the iOS 27.1 side controls: camera, clock and network glyph at the top, the hosted navigation bar's
/// items below them, and the hosted tab bar's items bottom-aligned. The real system bars are hidden while attached.
/// Navigation/toolbar items drive the real controllers via their target-action; tab items mirror and drive the real
/// tab bar's selection, including a SwiftUI `TabView`'s.
final class DuoFrameVerticalBar: UIView {

    /// Measured on the 27.1 Duo simulator: the outer camera / Dynamic Island occlusion region, and the safe-area inset
    /// the framed content clears, are both 84 pt.
    static let width: CGFloat = 84

    /// The strip's column (camera, status, items) is centred this far from the display's outer edge, not mid-strip.
    static let columnInset: CGFloat = 48

    var isOnRightEdge = true {
        didSet {
            guard isOnRightEdge != oldValue else { return }
            updateStackConstraints()
            setNeedsLayout()
        }
    }

    /// The camera cutout's diameter and its centre offset from the near end of the strip, exposed so the reserved-region
    /// overlay marks the occlusion at the same place the bar draws it.
    static var cameraDiameter: CGFloat { Metrics.cameraDiameter }
    static var cameraCentreOffset: CGFloat { Metrics.cameraCentreOffset }

    /// Where the camera cutout sits, driven by the pose. It is fixed to the hardware, so it rotates with the device;
    /// the inner display's camera is under-display and never shows.
    enum CameraPlacement {
        case top
        case bottom
        case hidden
    }

    var cameraPlacement: CameraPlacement = .top {
        didSet {
            guard cameraPlacement != oldValue else { return }
            updateStackConstraints()
            setNeedsLayout()
        }
    }

    // Measured on the 27.1 Duo simulator (camera occlusion region 37×37 at 29 pt, strip width 84, network ring centre
    // 130 below the camera or 77.3 without it, status pill 21 pt in from the edge). Item spacing is from the HIG.
    private enum Metrics {
        static let itemSide: CGFloat = 50
        static let groupSpacing: CGFloat = 8
        static let cameraDiameter: CGFloat = 37
        static let cameraEdgeInset: CGFloat = 29
        static let cameraCentreOffset: CGFloat = cameraEdgeInset + cameraDiameter / 2
        static let networkCentreOffset: CGFloat = 130
        static let noCameraNetworkCentre: CGFloat = 77.3
        static let statusPillInset: CGFloat = 21
        static let statusToItemsGap: CGFloat = 21
        static let topMargin: CGFloat = 24
        static let bottomMargin: CGFloat = 24
    }

    private(set) var isAttached = false
    private weak var root: UIViewController?
    private weak var hostView: UIView?
    private weak var tabBarController: UITabBarController?
    private weak var navigationController: UINavigationController?
    private weak var hiddenTabBarController: UITabBarController?
    // The navigation bar stays, as on the device: only its items move to the strip, keeping the title in place.
    private let hiddenBarItems = NSHashTable<UIBarButtonItem>.weakObjects()
    private let hiddenBackButtons = NSHashTable<UINavigationItem>.weakObjects()
    /// With the items gone, the device lifts a large title into the bar's own row (`.inline` is UIKit's public form of
    /// that layout), and once scrolled shows no bar at all rather than a collapsed title.
    private let inlinedTitles = NSMapTable<UINavigationItem, DuoFrameInlinedTitle>.weakToStrongObjects()
    private let hiddenTopEdgeEffects = NSHashTable<UIScrollView>.weakObjects()
    private weak var hiddenToolbarController: UINavigationController?
    private var refreshTimer: Timer?
    private var contentSignature = ""
    /// A sheet reaching under the strip keeps its own (horizontal) bars, so the strip shows only its status glyphs.
    private var isCoveredBySheet = false

    private let camera = UIView()
    private let status = DuoFrameStatusCluster()
    private let topStack = UIStackView()
    private let bottomStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true

        camera.backgroundColor = .black
        camera.isUserInteractionEnabled = false
        camera.layer.cornerRadius = Metrics.cameraDiameter / 2

        // The status cluster is positioned by frame (it moves to the camera's end); the two item stacks keep Auto
        // Layout, their end anchors driven by the placement.
        for stack in [topStack, bottomStack] {
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = Metrics.groupSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [status, camera, topStack, bottomStack] {
            addSubview(view)
        }
        camera.bounds = CGRect(x: 0, y: 0, width: Metrics.cameraDiameter, height: Metrics.cameraDiameter)

        topStackTop = topStack.topAnchor.constraint(equalTo: topAnchor, constant: statusZoneHeight)
        bottomStackBottom = bottomStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomMargin)
        topStackCentre = topStack.centerXAnchor.constraint(equalTo: leadingAnchor, constant: columnX)
        bottomStackCentre = bottomStack.centerXAnchor.constraint(equalTo: leadingAnchor, constant: columnX)
        NSLayoutConstraint.activate([topStackCentre, bottomStackCentre, topStackTop, bottomStackBottom])
    }

    private var topStackTop: NSLayoutConstraint!
    private var bottomStackBottom: NSLayoutConstraint!
    private var topStackCentre: NSLayoutConstraint!
    private var bottomStackCentre: NSLayoutConstraint!

    private var columnX: CGFloat {
        isOnRightEdge ? Self.width - Self.columnInset : Self.columnInset
    }

    /// The status glyphs and items always read clock, network, nav, tab from the top; the tab bar lifts clear of the
    /// camera only when the camera sits at the bottom. The constants depend only on the placement, so they update
    /// when it changes, not on every layout pass.
    private func updateStackConstraints() {
        topStackTop.constant = statusZoneHeight
        bottomStackBottom.constant = -(cameraPlacement == .bottom ? bottomCameraZone : Metrics.bottomMargin)
        topStackCentre.constant = columnX
        bottomStackCentre.constant = columnX
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameVerticalBar is created in code only")
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Attaching

    /// `root` is the controller whose real nav/tab bars this drives; `host` is the view it draws in. The host is the
    /// overlay chrome window's view, above the app window, so the strip stays visible over a full-screen presentation.
    /// The caller sizes and transforms the bar to sit over the framed content's controls edge.
    func attach(to root: UIViewController, in host: UIView) {
        self.root = root
        self.hostView = host
        status.sampledView = root.view.window
        isAttached = true
        isHidden = false
        host.insertSubview(self, at: 0)
        refresh()
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func setColourAdaptation(_ enabled: Bool) {
        guard isAttached else { return }
        status.setColourAdaptation(enabled)
    }

    func detach() {
        guard isAttached else { return }
        isAttached = false
        hostView = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        status.setColourAdaptation(false)
        restoreBars(keepingTabBar: nil, navigationController: nil)
        contentSignature = ""
        removeFromSuperview()
    }

    /// SwiftUI owns the bar controllers and may recreate them (login → main), swap them (tab change) or unhide a
    /// bar on its own updates, so this polls rather than trusting a one-off setup.
    private func refresh() {
        guard isAttached, let root else { return }
        if let host = hostView, superview !== host {
            host.insertSubview(self, at: 0)
        }
        // Follow the frontmost full-screen presentation: on a Duo a full-screen cover replaces the display, so the
        // strip reflects the cover's own bars (its tabs, its navigation), not the app's underneath. A sheet is a
        // shaped surface that keeps its own bars, so the walk stops before it.
        let containers = root.duoFrameFrontmostFullScreen.duoFrameOnScreenContainers
        tabBarController = containers.lazy.compactMap { $0 as? UITabBarController }.first
        navigationController = containers.reversed().lazy.compactMap { $0 as? UINavigationController }.first
        isCoveredBySheet = root.duoFrameFrontmostSheet.map(Self.coversStrip) ?? false
        hideBars()
        rebuildIfNeeded()
    }

    private static func coversStrip(_ sheet: UIViewController) -> Bool {
        guard let view = sheet.viewIfLoaded, let window = view.window else { return false }
        let overlap = DuoFramePresentationOverride.stripOverlap(of: view.convert(view.bounds, to: window), in: window)
        return overlap.left > 0 || overlap.right > 0
    }

    // MARK: - Hiding the real bars

    private func hideBars() {
        restoreBars(keepingTabBar: tabBarController, navigationController: navigationController)
        if let tabBarController, !tabBarController.duoFrameIsTabBarHidden {
            tabBarController.duoFrameIsTabBarHidden = true
            hiddenTabBarController = tabBarController
        }
        if let screen = navigationController?.topViewController {
            moveItemsToStrip(from: screen)
        }
        if let navigationController, !navigationController.isToolbarHidden {
            navigationController.setToolbarHidden(true, animated: false)
            hiddenToolbarController = navigationController
        }
    }

    /// Un-hides anything this view hid other than on the controllers to keep hidden (the navigation controller's top
    /// screen for its navigation bar, the controller itself for its toolbar).
    private func restoreBars(keepingTabBar tabBar: UITabBarController?, navigationController: UINavigationController?) {
        if let hiddenTabBarController, hiddenTabBarController !== tabBar {
            hiddenTabBarController.duoFrameIsTabBarHidden = false
            self.hiddenTabBarController = nil
        }
        restoreItems(keeping: navigationController?.topViewController)
        if let hiddenToolbarController, hiddenToolbarController !== navigationController {
            hiddenToolbarController.setToolbarHidden(false, animated: false)
            self.hiddenToolbarController = nil
        }
    }

    /// The navigation bar stays, as on the device: its items and back button move to the strip, and a large title
    /// goes inline and vanishes once scrolled.
    private func moveItemsToStrip(from screen: UIViewController) {
        let navigationItem = screen.navigationItem
        for item in Self.barItems(of: navigationItem) where !item.isHidden {
            item.isHidden = true
            hiddenBarItems.add(item)
        }
        if !navigationItem.hidesBackButton {
            navigationItem.hidesBackButton = true
            hiddenBackButtons.add(navigationItem)
        }
        if navigationItem.largeTitleDisplayMode.duoFrameShowsLargeTitle {
            inlinedTitles.setObject(DuoFrameInlinedTitle(navigationItem), forKey: navigationItem)
            navigationItem.largeTitleDisplayMode = .inline
            let bar = screen.navigationController?.navigationBar
            navigationItem.standardAppearance = (navigationItem.standardAppearance ?? bar?.standardAppearance)
                .map(Self.invisibleWhenScrolled)
        }
        if #available(iOS 26, *), inlinedTitles.object(forKey: navigationItem) != nil,
           let content = screen.viewIfLoaded {
            for scrollView in content.duoFrameScrollViews where !scrollView.topEdgeEffect.isHidden {
                scrollView.topEdgeEffect.isHidden = true
                hiddenTopEdgeEffects.add(scrollView)
            }
        }
    }

    private func restoreItems(keeping screen: UIViewController?) {
        let navigationItem = screen?.navigationItem
        let kept = navigationItem.map { Set(Self.barItems(of: $0).map(ObjectIdentifier.init)) } ?? []
        for item in hiddenBarItems.allObjects where !kept.contains(ObjectIdentifier(item)) {
            item.isHidden = false
            hiddenBarItems.remove(item)
        }
        for item in hiddenBackButtons.allObjects where item !== navigationItem {
            item.hidesBackButton = false
            hiddenBackButtons.remove(item)
        }
        if #available(iOS 26, *) {
            let content = screen?.viewIfLoaded
            for scrollView in hiddenTopEdgeEffects.allObjects where content.map(scrollView.isDescendant) != true {
                scrollView.topEdgeEffect.isHidden = false
                hiddenTopEdgeEffects.remove(scrollView)
            }
        }
        let inlined = inlinedTitles.keyEnumerator().allObjects.compactMap { $0 as? UINavigationItem }
        for item in inlined where item !== navigationItem {
            inlinedTitles.object(forKey: item)?.restore(item)
            inlinedTitles.removeObject(forKey: item)
        }
    }

    // MARK: - Building the stacks

    private func rebuildIfNeeded() {
        let topItem = isCoveredBySheet ? nil : navigationController?.topViewController?.navigationItem
        let showsBack = (navigationController?.viewControllers.count ?? 0) > 1
            && topItem.map { !$0.hidesBackButton || hiddenBackButtons.contains($0) } == true
        let leading = topItem.map(Self.leadingItems) ?? []
        let trailing = topItem.map(Self.trailingItems) ?? []
        let toolbar = hiddenToolbarController == nil || isCoveredBySheet
            ? []
            : (navigationController?.topViewController?.toolbarItems ?? []).filter(Self.isActionable)
        let tabs = isCoveredBySheet ? [] : tabBarController?.tabBar.items ?? []
        let selectedIndex = tabBarController?.selectedIndex ?? NSNotFound

        let signature = [
            "\(Int(bounds.height))",
            "\(showsBack)",
            Self.signature(of: leading),
            Self.signature(of: trailing),
            Self.signature(of: toolbar),
            tabs.map { "\(ObjectIdentifier($0).hashValue)" }.joined(separator: ","),
            "\(selectedIndex)"
        ].joined(separator: "|")
        guard signature != contentSignature else { return }
        let isFirstBuild = contentSignature.isEmpty
        contentSignature = signature

        var topCounts = [showsBack ? 1 : 0, leading.count, trailing.count].filter { $0 > 0 }
        let bottomCounts = [toolbar.count, tabs.count].filter { $0 > 0 }
        let bottomReserve = cameraPlacement == .bottom ? bottomCameraZone : Metrics.bottomMargin
        let available = bounds.height - statusZoneHeight - bottomReserve - Metrics.groupSpacing
        let overflows = Self.height(ofGroupCounts: topCounts) + Self.height(ofGroupCounts: bottomCounts) > available
            && !(leading + trailing).isEmpty
        if overflows {
            topCounts = [showsBack ? 1 : 0, 1].filter { $0 > 0 }
        }

        let rebuildStacks = { [self] in
            topStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            bottomStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            if showsBack {
                topStack.addArrangedSubview(makeGroup([makeBackButton()]))
            }
            if overflows {
                topStack.addArrangedSubview(makeGroup([makeOverflowButton(items: leading + trailing)]))
            } else {
                if !leading.isEmpty { topStack.addArrangedSubview(makeGroup(leading.map(makeItemView))) }
                if !trailing.isEmpty { topStack.addArrangedSubview(makeGroup(trailing.map(makeItemView))) }
            }
            if !toolbar.isEmpty {
                bottomStack.addArrangedSubview(makeGroup(toolbar.map(makeItemView)))
            }
            if !tabs.isEmpty {
                let buttons = tabs.enumerated().map { index, item in
                    makeTabButton(index: index, item: item, selected: index == selectedIndex)
                }
                bottomStack.addArrangedSubview(makeGroup(buttons))
            }
        }

        // Crossfade item changes — a cover hiding the tabs, a pushed back button, a tab selection. The first build has
        // nothing to fade from, so it's set directly.
        if isFirstBuild {
            rebuildStacks()
        } else {
            UIView.transition(
                with: self, duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction], animations: rebuildStacks
            )
        }
    }

    private static func height(ofGroupCounts counts: [Int]) -> CGFloat {
        guard !counts.isEmpty else { return 0 }
        return CGFloat(counts.reduce(0, +)) * Metrics.itemSide + CGFloat(counts.count - 1) * Metrics.groupSpacing
    }

    private static func signature(of items: [UIBarButtonItem]) -> String {
        items.map { "\(ObjectIdentifier($0).hashValue):\($0.isEnabled)" }.joined(separator: ",")
    }

    /// The bar's scrolled appearance with no background and a clear title; the unscrolled inline title is drawn from
    /// the large-title attributes, which stay as they were.
    private static func invisibleWhenScrolled(_ base: UINavigationBarAppearance) -> UINavigationBarAppearance {
        let appearance = base.copy()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = .clear
        appearance.backgroundImage = nil
        appearance.shadowColor = .clear
        appearance.shadowImage = nil
        appearance.titleTextAttributes[.foregroundColor] = UIColor.clear
        if #available(iOS 26, *) {
            appearance.subtitleTextAttributes[.foregroundColor] = UIColor.clear
        }
        return appearance
    }

    private static func barItems(of navigationItem: UINavigationItem) -> [UIBarButtonItem] {
        allLeadingItems(of: navigationItem) + allTrailingItems(of: navigationItem)
    }

    private static func leadingItems(of navigationItem: UINavigationItem) -> [UIBarButtonItem] {
        allLeadingItems(of: navigationItem).filter(isActionable)
    }

    private static func trailingItems(of navigationItem: UINavigationItem) -> [UIBarButtonItem] {
        allTrailingItems(of: navigationItem).filter(isActionable)
    }

    private static func allLeadingItems(of navigationItem: UINavigationItem) -> [UIBarButtonItem] {
        let grouped = navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
        return grouped.isEmpty ? navigationItem.leftBarButtonItems ?? [] : grouped
    }

    private static func allTrailingItems(of navigationItem: UINavigationItem) -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        if #available(iOS 26, *), let pinned = navigationItem.pinnedTrailingGroup {
            items += pinned.barButtonItems
        }
        let grouped = navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
        items += grouped.isEmpty ? navigationItem.rightBarButtonItems ?? [] : grouped
        return items
    }

    private static func isActionable(_ item: UIBarButtonItem) -> Bool {
        item.customView != nil || item.image != nil || item.title != nil || item.menu != nil
            || item.primaryAction != nil
    }

    // MARK: - Making views

    private func makeGroup(_ views: [UIView]) -> UIView {
        let glass = UIVisualEffectView.duoFrameGlass(fallbackRadius: Metrics.itemSide / 2)
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            glass.widthAnchor.constraint(equalToConstant: Metrics.itemSide)
        ])
        return glass
    }

    private static func makeCircleButton(symbol: String? = nil, weight: UIImage.SymbolWeight = .medium) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: weight)
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.itemSide),
            button.heightAnchor.constraint(equalToConstant: Metrics.itemSide)
        ])
        return button
    }

    private func makeBackButton() -> UIButton {
        let button = Self.makeCircleButton(symbol: "chevron.backward", weight: .semibold)
        button.accessibilityLabel = "Back"
        button.addAction(UIAction { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }, for: .primaryActionTriggered)
        return button
    }

    private func makeOverflowButton(items: [UIBarButtonItem]) -> UIButton {
        let button = Self.makeCircleButton(symbol: "ellipsis")
        button.accessibilityLabel = "More"
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: items.compactMap { item -> UIMenuElement? in
            if let menu = item.menu { return menu }
            guard item.customView == nil else { return nil }
            return UIAction(
                title: item.title ?? item.accessibilityLabel ?? "Item",
                image: item.image,
                attributes: item.isEnabled ? [] : .disabled
            ) { [weak item] _ in
                item.map(Self.perform)
            }
        })
        return button
    }

    private func makeItemView(for item: UIBarButtonItem) -> UIView {
        if let customView = item.customView {
            return DuoFrameCentringBox(wrapping: customView, side: Metrics.itemSide)
        }
        let button = Self.makeCircleButton()
        var configuration = button.configuration ?? .plain()
        if let image = item.image {
            configuration.image = image.duoFrameFitted(to: 24)
        } else {
            configuration.title = item.title
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: 11, weight: .medium)
                return attributes
            }
        }
        configuration.baseForegroundColor = item.tintColor ?? .label
        button.configuration = configuration
        button.isEnabled = item.isEnabled
        button.accessibilityLabel = item.title ?? item.accessibilityLabel
        button.menu = item.menu
        if item.primaryAction == nil, item.action == nil {
            button.showsMenuAsPrimaryAction = item.menu != nil
        }
        button.addAction(UIAction { [weak item] _ in
            item.map(Self.perform)
        }, for: .primaryActionTriggered)
        return button
    }

    private static func perform(_ item: UIBarButtonItem) {
        if let primaryAction = item.primaryAction {
            UIControl().sendAction(primaryAction)
        } else if let action = item.action {
            UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        }
    }

    private func makeTabButton(index: Int, item: UITabBarItem, selected: Bool) -> UIButton {
        let button = Self.makeCircleButton()
        var configuration = button.configuration ?? .plain()
        let image = selected ? item.selectedImage ?? item.image : item.image
        configuration.image = image?.duoFrameFitted(to: 26)
        configuration.baseForegroundColor = selected ? tabBarController?.tabBar.tintColor ?? tintColor : .label
        if selected {
            configuration.background.backgroundColor = UIColor.label.withAlphaComponent(0.1)
            configuration.background.backgroundInsets = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
            configuration.cornerStyle = .capsule
        }
        button.configuration = configuration
        button.accessibilityLabel = item.title
        button.addAction(UIAction { [weak self] _ in
            self?.selectTab(index)
        }, for: .primaryActionTriggered)
        return button
    }

    private func selectTab(_ index: Int) {
        tabBarController?.duoFrameSelectTab(at: index)
        refresh()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if isAttached {
            rebuildIfNeeded()
        }
        layoutStatusCluster()
    }

    /// The clock and network sit below the camera only when it's at the top, pushing them (and the nav items) down.
    private var networkCentre: CGFloat {
        cameraPlacement == .top ? Metrics.networkCentreOffset : Metrics.noCameraNetworkCentre
    }

    private var statusZoneHeight: CGFloat {
        networkCentre + DuoFrameStatusCluster.glyphSide / 2 + Metrics.statusToItemsGap
    }

    /// Space the bottom tab bar leaves clear for a camera cutout sitting in the bottom corner.
    private var bottomCameraZone: CGFloat {
        Metrics.cameraCentreOffset + Metrics.cameraDiameter / 2 + Metrics.bottomMargin
    }

    /// The clock and network always read from the top (clock, network, nav, tab). The camera is a separate cutout at
    /// its physical corner: above the clock when it's at the top, alone in the bottom corner when it's at the bottom.
    private func layoutStatusCluster() {
        let centreX = columnX
        status.frame = bounds
        camera.isHidden = cameraPlacement == .hidden
        switch cameraPlacement {
        case .top:
            camera.center = CGPoint(x: centreX, y: Metrics.cameraCentreOffset)
        case .bottom:
            camera.center = CGPoint(x: centreX, y: bounds.height - Metrics.cameraCentreOffset)
        case .hidden:
            break
        }
        status.place(ring: CGPoint(x: centreX, y: networkCentre), axis: .vertical(pillStart: Metrics.statusPillInset))
    }

    /// Only the stand-in controls take touches; the rest of the strip lets the app's content underneath receive them.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view == self ? nil : view
    }
}

/// Centres a bar button item's custom view without changing how it lays itself out, so the navigation bar can take
/// it back once the stand-in is removed.
private final class DuoFrameCentringBox: UIView {

    private let wrapped: UIView
    /// The navigation bar still lays out its (hidden) items' custom views, resetting their origin to zero, so the view
    /// is centred by moving this container rather than the view itself.
    private let container = UIView()

    init(wrapping view: UIView, side: CGFloat) {
        wrapped = view
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        addSubview(container)
        container.addSubview(view)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameCentringBox is created in code only")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        wrapped.sizeToFit()
        wrapped.frame.origin = .zero
        let size = wrapped.bounds.size
        container.frame = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }
}

private extension UIView {
    var duoFrameScrollViews: [UIScrollView] {
        (self as? UIScrollView).map { [$0] } ?? subviews.flatMap(\.duoFrameScrollViews)
    }
}

/// What inlining a navigation item's title changed, to put back when the strip lets go of it.
private final class DuoFrameInlinedTitle {
    private let largeTitleDisplayMode: UINavigationItem.LargeTitleDisplayMode
    private let standardAppearance: UINavigationBarAppearance?

    init(_ item: UINavigationItem) {
        largeTitleDisplayMode = item.largeTitleDisplayMode
        standardAppearance = item.standardAppearance
    }

    func restore(_ item: UINavigationItem) {
        item.largeTitleDisplayMode = largeTitleDisplayMode
        item.standardAppearance = standardAppearance
    }
}

private extension UINavigationItem.LargeTitleDisplayMode {
    var duoFrameShowsLargeTitle: Bool {
        switch self {
        case .automatic, .always: true
        case .never, .inline: false
        @unknown default: false
        }
    }
}
#endif
