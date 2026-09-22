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
/// Navigation/toolbar items drive the real controllers via their target-action; tab items mirror the real tab bar's
/// selection but can only drive a UIKit-owned tab controller, not a SwiftUI `TabView` (see `selectTab`).
final class DuoFrameVerticalBar: UIView {

    /// Measured on the 27.1 Duo simulator: the outer camera / Dynamic Island occlusion region, and the safe-area inset
    /// the framed content clears, are both 84 pt.
    static let width: CGFloat = 84

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

    // The camera diameter and the strip width are measured on the 27.1 Duo simulator (camera occlusion region 37×37,
    // strip width 84). The clock/network offsets are still read from the HIG "Designing for iPhone Duo" screenshots;
    // offsets are from the near end (top or bottom) of the status cluster.
    private enum Metrics {
        static let itemSide: CGFloat = 50
        static let groupSpacing: CGFloat = 8
        static let cameraDiameter: CGFloat = 37
        static let cameraEdgeInset: CGFloat = 28
        static let cameraCentreOffset: CGFloat = cameraEdgeInset + cameraDiameter / 2
        static let clockCentreOffset: CGFloat = 92
        static let networkCentreOffset: CGFloat = 131
        static let networkSide: CGFloat = 42
        static let statusToItemsGap: CGFloat = 21
        static let topMargin: CGFloat = 24
        static let bottomMargin: CGFloat = 24
        // With no camera, the clock and network slide up into the vacated corner. Measured on the 27.1 Duo simulator
        // (inner landscape): clock centre 40, network centre 73.
        static let noCameraClockCentre: CGFloat = 40
        static let noCameraNetworkCentre: CGFloat = 73
    }

    private(set) var isAttached = false
    private weak var root: UIViewController?
    private weak var hostView: UIView?
    private weak var tabBarController: UITabBarController?
    private weak var navigationController: UINavigationController?
    private weak var hiddenTabBarController: UITabBarController?
    private weak var hiddenNavigationBarController: UINavigationController?
    private weak var hiddenToolbarController: UINavigationController?
    private var refreshTimer: Timer?
    private var colourTimer: Timer?
    private var contentSignature = ""
    private var clockPrefersDark: Bool?
    private var networkPrefersDark: Bool?

    /// How often the clock and network glyphs re-sample the content beneath them. Faster tracks scrolling more closely
    /// but each tick renders the app content, so it trades against CPU.
    private static let colourSampleInterval: TimeInterval = 0.12
    fileprivate static let darkForegroundLuminance: CGFloat = 0.6

    private let camera = UIView()
    private let clock = UILabel()
    private let network = DuoFrameNetworkGlyph()
    private let topStack = UIStackView()
    private let bottomStack = UIStackView()
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        formatter.amSymbol = ""
        formatter.pmSymbol = ""
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true

        camera.backgroundColor = .black
        camera.isUserInteractionEnabled = false
        camera.layer.cornerRadius = Metrics.cameraDiameter / 2

        // Monospaced digits so the label's width is stable as the minutes change and the text never truncates.
        clock.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        clock.textColor = .label
        clock.textAlignment = .center
        clock.isUserInteractionEnabled = false

        network.isUserInteractionEnabled = false

        // The status glyphs are positioned by frame (the cluster moves to the camera's end); the two item stacks keep
        // Auto Layout, their end anchors driven by the placement.
        for stack in [topStack, bottomStack] {
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = Metrics.groupSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [camera, clock, network, topStack, bottomStack] {
            addSubview(view)
        }
        camera.bounds = CGRect(x: 0, y: 0, width: Metrics.cameraDiameter, height: Metrics.cameraDiameter)
        network.bounds = CGRect(x: 0, y: 0, width: Metrics.networkSide, height: Metrics.networkSide)

        topStackTop = topStack.topAnchor.constraint(equalTo: topAnchor, constant: statusZoneHeight)
        bottomStackBottom = bottomStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomMargin)
        NSLayoutConstraint.activate([
            topStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            topStackTop, bottomStackBottom
        ])
    }

    private var topStackTop: NSLayoutConstraint!
    private var bottomStackBottom: NSLayoutConstraint!

    /// The status glyphs and items always read clock, network, nav, tab from the top; the tab bar lifts clear of the
    /// camera only when the camera sits at the bottom. The constants depend only on the placement, so they update
    /// when it changes, not on every layout pass.
    private func updateStackConstraints() {
        topStackTop.constant = statusZoneHeight
        bottomStackBottom.constant = -(cameraPlacement == .bottom ? bottomCameraZone : Metrics.bottomMargin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameVerticalBar is created in code only")
    }

    deinit {
        refreshTimer?.invalidate()
        colourTimer?.invalidate()
    }

    // MARK: - Attaching

    /// `root` is the controller whose real nav/tab bars this drives; `host` is the view it draws in. The host is the
    /// overlay chrome window's view, above the app window, so the strip stays visible over a full-screen presentation.
    /// The caller sizes and transforms the bar to sit over the framed content's controls edge.
    func attach(to root: UIViewController, in host: UIView) {
        self.root = root
        self.hostView = host
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

    // MARK: - Colour adaptation

    /// Turns the clock/network colour sampling on or off. Reconciled from the current setting on every layout update,
    /// so it applies live: enabling starts the sampling timer, disabling stops it and returns the glyphs to `.label`.
    func setColourAdaptation(_ enabled: Bool) {
        guard isAttached else { return }
        if enabled {
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

    func detach() {
        guard isAttached else { return }
        isAttached = false
        hostView = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        colourTimer?.invalidate()
        colourTimer = nil
        clockPrefersDark = nil
        networkPrefersDark = nil
        restoreBars(keepingTabBar: nil, navigationBar: nil, toolbar: nil)
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
        let time = clockFormatter.string(from: .now).trimmingCharacters(in: .whitespaces)
        if clock.text != time {
            clock.text = time
            setNeedsLayout()   // re-size and re-centre the label for the new value
        }

        // Follow the frontmost full-screen presentation: on a Duo a full-screen cover replaces the display, so the
        // strip reflects the cover's own bars (its tabs, its navigation), not the app's underneath. A sheet is a
        // shaped surface that keeps its own bars, so the walk stops before it.
        let containers = Self.onScreenContainers(in: Self.frontmostFullScreen(from: root))
        tabBarController = containers.lazy.compactMap { $0 as? UITabBarController }.first
        navigationController = containers.reversed().lazy.compactMap { $0 as? UINavigationController }.first
        hideBars()
        rebuildIfNeeded()
    }

    /// The deepest full-screen presentation above `controller`, or `controller` itself when nothing full-screen is
    /// presented. Sheets and popovers stop the walk.
    private static func frontmostFullScreen(from controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController,
              !presented.isBeingDismissed,
              presented.duoFrameIsFullScreenPresentation {
            top = presented
        }
        return top
    }

    // MARK: - Adaptive glyph colour

    /// The real status bar picks a dark or light foreground per region from the content beneath it. This mirrors that:
    /// it samples the app content under the clock and under the network glyph separately and flips each to black or
    /// white. Both glyphs sit near the top of the strip, so one render of the app content covers them and each is
    /// averaged from its own sub-rect.
    private func sampleStatusColours() {
        guard isAttached, window != nil, let appWindow = root?.view.window else { return }
        let clockRegion = clock.convert(clock.bounds, to: appWindow).integral
        let networkRegion = network.convert(network.bounds, to: appWindow).integral
        let union = clockRegion.union(networkRegion).intersection(appWindow.bounds)
        guard !union.isNull, union.width >= 1, union.height >= 1,
              let snapshot = Self.snapshot(of: appWindow, region: union)?.cgImage else { return }

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

    /// Container controllers whose views are on screen, in hierarchy order, so the last navigation controller is the
    /// one driving the visible screen.
    private static func onScreenContainers(in controller: UIViewController) -> [UIViewController] {
        guard controller.isViewLoaded, controller.view.window != nil else { return [] }
        var result: [UIViewController] = []
        if controller is UITabBarController || controller is UINavigationController {
            result.append(controller)
        }
        for child in controller.children {
            result += onScreenContainers(in: child)
        }
        return result
    }

    // MARK: - Hiding the real bars

    private func hideBars() {
        restoreBars(keepingTabBar: tabBarController, navigationBar: navigationController, toolbar: navigationController)
        if let tabBarController, !isTabBarHidden(tabBarController) {
            setTabBar(hidden: true, on: tabBarController)
            hiddenTabBarController = tabBarController
        }
        if let navigationController, !navigationController.isNavigationBarHidden {
            navigationController.setNavigationBarHidden(true, animated: false)
            hiddenNavigationBarController = navigationController
        }
        if let navigationController, !navigationController.isToolbarHidden {
            navigationController.setToolbarHidden(true, animated: false)
            hiddenToolbarController = navigationController
        }
    }

    /// Un-hides any bar this view hid on a controller other than the one to keep hidden.
    private func restoreBars(
        keepingTabBar tabBar: UITabBarController?,
        navigationBar: UINavigationController?,
        toolbar: UINavigationController?
    ) {
        if let hiddenTabBarController, hiddenTabBarController !== tabBar {
            setTabBar(hidden: false, on: hiddenTabBarController)
            self.hiddenTabBarController = nil
        }
        if let hiddenNavigationBarController, hiddenNavigationBarController !== navigationBar {
            hiddenNavigationBarController.setNavigationBarHidden(false, animated: false)
            self.hiddenNavigationBarController = nil
        }
        if let hiddenToolbarController, hiddenToolbarController !== toolbar {
            hiddenToolbarController.setToolbarHidden(false, animated: false)
            self.hiddenToolbarController = nil
        }
    }

    private func isTabBarHidden(_ tabBarController: UITabBarController) -> Bool {
        if #available(iOS 18, *) {
            return tabBarController.isTabBarHidden
        }
        return tabBarController.tabBar.isHidden
    }

    private func setTabBar(hidden: Bool, on tabBarController: UITabBarController) {
        if #available(iOS 18, *) {
            tabBarController.isTabBarHidden = hidden
        } else {
            tabBarController.tabBar.isHidden = hidden
        }
    }

    // MARK: - Building the stacks

    private func rebuildIfNeeded() {
        let topItem = navigationController?.topViewController?.navigationItem
        let showsBack = (navigationController?.viewControllers.count ?? 0) > 1 && topItem?.hidesBackButton == false
        let leading = topItem.map(Self.leadingItems) ?? []
        let trailing = topItem.map(Self.trailingItems) ?? []
        let toolbar = hiddenToolbarController == nil
            ? []
            : (navigationController?.topViewController?.toolbarItems ?? []).filter(Self.isActionable)
        let tabs = tabBarController?.tabBar.items ?? []
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

    private static func leadingItems(of navigationItem: UINavigationItem) -> [UIBarButtonItem] {
        let grouped = navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
        return (grouped.isEmpty ? navigationItem.leftBarButtonItems ?? [] : grouped).filter(isActionable)
    }

    private static func trailingItems(of navigationItem: UINavigationItem) -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        if #available(iOS 26, *), let pinned = navigationItem.pinnedTrailingGroup {
            items += pinned.barButtonItems
        }
        let grouped = navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
        items += grouped.isEmpty ? navigationItem.rightBarButtonItems ?? [] : grouped
        return items.filter(isActionable)
    }

    private static func isActionable(_ item: UIBarButtonItem) -> Bool {
        item.customView != nil || item.image != nil || item.title != nil || item.menu != nil
            || item.primaryAction != nil
    }

    // MARK: - Making views

    private func makeGroup(_ views: [UIView]) -> UIView {
        let glass = Self.makeGlass()
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

    private static func makeGlass() -> UIVisualEffectView {
        let glass: UIVisualEffectView
        if #available(iOS 26, *) {
            glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .capsule()
        } else {
            glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            glass.clipsToBounds = true
            glass.layer.cornerRadius = Metrics.itemSide / 2
        }
        glass.translatesAutoresizingMaskIntoConstraints = false
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
            configuration.image = Self.fitted(image, to: 24)
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
        configuration.image = image.map { Self.fitted($0, to: 26) }
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

    /// Best effort selection. Drives a UIKit-owned `UITabBarController` (the portable case). A SwiftUI-native
    /// `TabView` binds its content to its own selection state and ignores external selection entirely — proven by
    /// experiment: its private `UIKitTabBarController` accepts `selectedIndex`/`selectedTab` and the delegate call,
    /// but the displayed tab never follows. There the side tabs mirror the real selection but can't change it; turn
    /// the simulator off to navigate, or use the real iOS 27.1 vertical bars.
    private func selectTab(_ index: Int) {
        guard let tabBarController else { return }
        if #available(iOS 18, *), tabBarController.tabs.indices.contains(index) {
            tabBarController.selectedTab = tabBarController.tabs[index]
        } else if let controllers = tabBarController.viewControllers, controllers.indices.contains(index) {
            tabBarController.selectedIndex = index
        }
        let tabBar = tabBarController.tabBar
        if let items = tabBar.items, items.indices.contains(index) {
            tabBar.delegate?.tabBar?(tabBar, didSelect: items[index])
        }
        refresh()
    }

    private static func fitted(_ image: UIImage, to side: CGFloat) -> UIImage {
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let scaled = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.withRenderingMode(image.renderingMode)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if isAttached {
            rebuildIfNeeded()
        }
        layoutStatusCluster()
    }

    /// Height reserved at the top for the clock and network before the nav items begin. The clock and network sit
    /// below the camera only when it's at the top, so that pushes them (and the nav items) down.
    private var statusZoneHeight: CGFloat {
        let networkCentre = cameraPlacement == .top ? Metrics.networkCentreOffset : Metrics.noCameraNetworkCentre
        return networkCentre + Metrics.networkSide / 2 + Metrics.statusToItemsGap
    }

    /// Space the bottom tab bar leaves clear for a camera cutout sitting in the bottom corner.
    private var bottomCameraZone: CGFloat {
        Metrics.cameraCentreOffset + Metrics.cameraDiameter / 2 + Metrics.bottomMargin
    }

    /// The clock and network always read from the top (clock, network, nav, tab). The camera is a separate cutout at
    /// its physical corner: above the clock when it's at the top, alone in the bottom corner when it's at the bottom.
    private func layoutStatusCluster() {
        let centreX = bounds.width / 2
        camera.isHidden = cameraPlacement == .hidden
        clock.sizeToFit()
        switch cameraPlacement {
        case .top:
            camera.center = CGPoint(x: centreX, y: Metrics.cameraCentreOffset)
        case .bottom:
            camera.center = CGPoint(x: centreX, y: bounds.height - Metrics.cameraCentreOffset)
        case .hidden:
            break
        }
        let clockY = cameraPlacement == .top ? Metrics.clockCentreOffset : Metrics.noCameraClockCentre
        let networkY = cameraPlacement == .top ? Metrics.networkCentreOffset : Metrics.noCameraNetworkCentre
        clock.center = CGPoint(x: centreX, y: clockY)
        network.center = CGPoint(x: centreX, y: networkY)
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

    init(wrapping view: UIView, side: CGFloat) {
        wrapped = view
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        addSubview(view)
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
        wrapped.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// The Duo status bar's combined Wi‑Fi and cellular glyph: a ring open at the bottom, Wi‑Fi inside, signal dots below.
private final class DuoFrameNetworkGlyph: UIView {

    var foregroundColor: UIColor = .label {
        didSet {
            guard foregroundColor != oldValue else { return }
            wifi.tintColor = foregroundColor
            setNeedsDisplay()
        }
    }

    private static let wifiConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    private let wifi = UIImageView(image: UIImage(systemName: "wifi", withConfiguration: wifiConfiguration))

    override init(frame: CGRect) {
        super.init(frame: frame)
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
        wifi.frame = CGRect(x: bounds.midX - 12, y: 5.5, width: 24, height: 24)
    }

    override func draw(_ rect: CGRect) {
        foregroundColor.setStroke()
        foregroundColor.setFill()
        let centre = CGPoint(x: bounds.midX, y: 17)
        let ring = UIBezierPath(
            arcCenter: centre, radius: 15, startAngle: 2 * .pi / 3, endAngle: .pi / 3, clockwise: true
        )
        ring.lineWidth = 2
        ring.lineCapStyle = .round
        ring.stroke()
        for degrees in [68.0, 83.0, 97.0, 112.0] {
            let angle = degrees * .pi / 180
            let dot = CGPoint(x: centre.x + 19 * cos(angle), y: centre.y + 19 * sin(angle))
            UIBezierPath(ovalIn: CGRect(x: dot.x - 1.4, y: dot.y - 1.4, width: 2.8, height: 2.8)).fill()
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
        return luminance > DuoFrameVerticalBar.darkForegroundLuminance
    }
}
#endif
