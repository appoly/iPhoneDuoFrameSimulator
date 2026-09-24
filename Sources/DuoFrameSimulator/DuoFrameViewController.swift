//
//  DuoFrameViewController.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

/// Hosts the app's real root and frames it by resizing the *window*, not the content within it. Because the whole
/// window is sized to the footprint (and scaled for Display Zoom), window-level presentations — `.sheet`,
/// `.fullScreenCover`, alerts, popovers — are constrained to the simulated device too, which content-only scaling
/// could never reach. Debug chrome (outline, caption, menu button, split companion) lives in a separate passthrough
/// window above the app window, and the backdrop and device bezel in a non-interactive one below it.
final class DuoFrameViewController: UIViewController {

    let root: UIViewController

    var settings: DuoFrameSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            apply()
        }
    }

    private let windowMaskLayer = CAShapeLayer()
    private lazy var menuButton = DuoFrameMenuButton(controller: self)
    private lazy var chrome = DuoFrameChromeViewController(menuButton: menuButton)
    private let verticalBar = DuoFrameVerticalBar()
    private let tabBar = DuoFrameTabBar()
    private let cornerStatus = DuoFrameStatusCluster()
    private let shield: DuoFrameShieldViewController
    private var chromeWindow: UIWindow?
    private let backdrop = DuoFrameBackdropViewController()
    private var backdropWindow: UIWindow?
    private var appliedScale: CGFloat = 1
    private var hasAppliedScreenOverrides = false
    private var isFramingWindow = false
    private var isWindowFramed = false
    private var hostStatusBarInset: CGFloat = 0
    private let tabBarBuiltAsPhone = NSMapTable<UITabBarController, NSNumber>.weakToStrongObjects()

    private static let splitGutter: CGFloat = 14

    init(hosting root: UIViewController) {
        self.root = root
        shield = DuoFrameShieldViewController(content: root)
        settings = DuoFrameSettings.load()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameViewController is created in code only")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // The framed window still reports the host's real safe area to its root view, and `additionalSafeAreaInsets`
        // can only add to that, so a frame smaller than the host could never sit above the host's insets. The shield's
        // view is pinned inside this view's safe area, so it inherits nothing; the hosted root overhangs it to fill the
        // frame while taking its whole (faked) safe area from `additionalSafeAreaInsets`.
        addChild(shield)
        view.addSubview(shield.view)
        shield.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            shield.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            shield.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            shield.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            shield.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        shield.didMove(toParent: self)

        apply()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureChromeWindow()
        // Be a first responder so shake events have somewhere to start when the app has none; being the root also
        // puts this controller at the end of every responder chain, so a shake bubbles up here to toggle the button.
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            menuButton.isHidden.toggle()
        }
        super.motionEnded(motion, with: event)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        frameWindow()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        frameWindow()
    }

    // MARK: - Forwarding to the hosted root

    override var childForStatusBarStyle: UIViewController? { shield }
    override var childForStatusBarHidden: UIViewController? { shield }
    override var childForHomeIndicatorAutoHidden: UIViewController? { shield }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { shield }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { root.supportedInterfaceOrientations }

    // MARK: - Applying settings

    private func apply() {
        // A settings change means a menu choice was made, so the menu is closing; clear the swallow flag.
        menuButton.isMenuOpen = false
        recordTabBarStyles()
        applyTraitOverrides()
        applyScreenOverrides()
        verticalBar.cameraPlacement = cameraPlacement(for: settings.geometry)
        // The bar is attached and positioned in `frameWindow`, once the overlay window that hosts it exists.
        frameWindow()
        updateTabBarNotice()
    }

    /// The outer display's camera is a physical cutout that rotates with the device; the inner display's is
    /// under-display and invisible, and an other-device frame makes no claim about a camera. In landscape the camera
    /// follows the rotation: bottom of the strip with the controls on the right, top of it with them on the left.
    private func cameraPlacement(for geometry: DuoFrameGeometry?) -> DuoFrameVerticalBar.CameraPlacement {
        guard let geometry else { return .hidden }
        switch geometry.preset {
        case .outerPortrait: return .top
        case .outerLandscape: return (geometry.sideEdge?.isRight ?? true) ? .bottom : .top
        case .innerLandscape, .innerPortrait, .innerSplitHalf, .otherDevice, .off: return .hidden
        }
    }

    private func applyTraitOverrides() {
        if let geometry = settings.geometry, settings.overridesSizeClasses {
            root.traitOverrides.horizontalSizeClass = geometry.horizontalSizeClass
            root.traitOverrides.verticalSizeClass = geometry.verticalSizeClass
        } else {
            root.traitOverrides.remove(UITraitHorizontalSizeClass.self)
            root.traitOverrides.remove(UITraitVerticalSizeClass.self)
        }
        if settings.geometry != nil {
            root.traitOverrides.userInterfaceIdiom = .phone
        } else {
            root.traitOverrides.remove(UITraitUserInterfaceIdiom.self)
        }
    }

    // MARK: - Tab bar style

    /// A tab bar controller fixes its iPad-or-phone style at its first layout, so each is tagged with the idiom the
    /// root carries when first seen — before this settings change alters it, so still the one it was built under.
    private func recordTabBarStyles() {
        let isPhone = NSNumber(value: root.traitOverrides.contains(UITraitUserInterfaceIdiom.self))
        for tabs in appTabBarControllers where tabBarBuiltAsPhone.object(forKey: tabs) == nil {
            tabBarBuiltAsPhone.setObject(isPhone, forKey: tabs)
        }
    }

    /// Only an iPad host on 18+ has a second (floating top) style, and compact width forces the bottom bar anyway.
    private func updateTabBarNotice() {
        guard #available(iOS 18, *), UIDevice.current.userInterfaceIdiom == .pad else { return }
        let wantsPhone = root.traitOverrides.contains(UITraitUserInterfaceIdiom.self)
        root.updateTraitsIfNeeded()
        let isStale = root.traitCollection.horizontalSizeClass == .regular && appTabBarControllers.contains { tabs in
            guard tabs.viewIfLoaded?.window != nil, !tabs.isTabBarHidden else { return false }
            return tabBarBuiltAsPhone.object(forKey: tabs).map { $0.boolValue != wantsPhone } ?? false
        }
        guard isStale else {
            chrome.notice = nil
            return
        }
        chrome.notice = wantsPhone
            ? "Tab bars keep the style they launched with. Relaunch to see the phone-style tab bar."
            : "Tab bars keep the style they launched with. Relaunch to restore the iPad tab bar."
    }

    /// The app root's tree plus anything presented over it (presentations hang off this controller, the window root).
    private var appTabBarControllers: [UITabBarController] {
        var trees = [root]
        var presented = presentedViewController
        while let next = presented {
            trees.append(next)
            presented = next.presentedViewController
        }
        return trees.flatMap(\.tabBarControllersInTree)
    }

    private func applyScreenOverrides() {
        let geometry = settings.geometry
        let zoom = geometry.flatMap { $0.zoom == 1 ? nil : $0.zoom }
        let bounds = settings.overridesScreenBounds ? geometry?.layoutSize : nil
        let changed = zoom != DuoFrameScreenOverride.zoom || bounds != DuoFrameScreenOverride.bounds
        DuoFrameScreenOverride.zoom = zoom
        DuoFrameScreenOverride.bounds = bounds
        // The first application is the launch state; nothing has read the old values yet, so no rebuild is needed.
        if changed, hasAppliedScreenOverrides {
            NotificationCenter.default.post(name: DuoFrameSimulator.screenMetricsDidChange, object: nil)
        }
        hasAppliedScreenOverrides = true
    }

    private func ensureBackdropWindow() {
        guard backdropWindow == nil, let scene = view.window?.windowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        window.rootViewController = backdrop
        backdropWindow = window
        window.isHidden = false
    }

    private func ensureChromeWindow() {
        guard chromeWindow == nil, let scene = view.window?.windowScene else { return }
        let window = DuoFramePassthroughWindow(windowScene: scene)
        // Above the app window so the menu button is reachable even when the frame fills the screen; the passthrough
        // window forwards every touch that misses the button down to the app window.
        window.windowLevel = .normal + 1
        window.isMenuOpen = { [weak self] in self?.menuButton.isMenuOpen ?? false }
        window.onOutsideTapWhileMenuOpen = { [weak self] in self?.menuButton.dismissMenuIfOpen() }
        // Full screen: its safe area is the host's real device insets, the source for the framed root's overlap.
        chrome.onSafeAreaChange = { [weak self] in self?.frameWindow() }
        chrome.appearanceSource = self   // self → shield → content → app root
        window.rootViewController = chrome
        // Assign before showing: making the window visible lays the chrome out synchronously, which can call back in
        // here; the stored reference stops a second window being built (and `chrome` re-rooted onto it).
        chromeWindow = window
        window.isHidden = false
    }

    // MARK: - Framing the window

    private func frameWindow() {
        guard !isFramingWindow, let window = view.window, let scene = window.windowScene else { return }
        // Raise the guard before touching the chrome window: showing it lays the chrome out synchronously and can
        // re-enter through `onSafeAreaChange`, which must be ignored until this pass finishes.
        isFramingWindow = true
        defer { isFramingWindow = false }
        ensureChromeWindow()
        ensureBackdropWindow()
        // Re-query the mirrored host preferences; the overlay window is frontmost, so it, not the app window, is the
        // one UIKit consults. Flags only, so no re-entrancy through the overrides during this pass.
        chrome.setNeedsStatusBarAppearanceUpdate()
        chrome.setNeedsUpdateOfHomeIndicatorAutoHidden()

        // The scene, not the screen: on iPad the scene shrinks for Split View, Stage Manager and window resizing,
        // and UIKit re-lays the window out to match. Framing against the screen would fight that every pass.
        let arena = scene.coordinateSpace.bounds
        guard let geometry = settings.geometry else {
            // Off: hand the window back to UIKit once, then leave it alone so it can follow the scene. The shield
            // still zeroes what the root inherits, so hand it the host's real insets to reproduce normal behaviour.
            if isWindowFramed {
                resetWindow(window, to: arena)
                isWindowFramed = false
            }
            let host = view.safeAreaInsets
            if root.additionalSafeAreaInsets != host { root.additionalSafeAreaInsets = host }
            DuoFramePresentationOverride.framedWindow = nil
            chrome.clear()
            backdrop.clear()
            chrome.hidesHostStatusBar = false
            chrome.hidesHostHomeIndicator = false
            verticalBar.detach()
            tabBar.detach()
            cornerStatus.removeFromSuperview()
            appliedScale = 1
            return
        }

        // A split pose lays the app and a companion pane across a full-inner-display stage; every other pose fills
        // its own footprint. Both share the fit-scale maths. Fit is to the whole screen: a frame the size of the
        // screen renders 1:1, a smaller one at true point size centred, only a larger one scales below 1. A forced
        // bezel counts as part of the device, on both sides so the frame stays centred.
        let stage = geometry.isSplit
            ? CGSize(width: geometry.size.width * 2 + Self.splitGutter, height: geometry.size.height)
            : geometry.size
        let reach = settings.alwaysShowsBezel ? DuoFrameBezel.reach(geometry: geometry, display: stage) : .zero
        let fit = min(
            arena.width / (stage.width + reach.width * 2),
            arena.height / (stage.height + reach.height * 2)
        )
        let scale = settings.matchesPhysicalDensity ? min(fit, physicalScale(for: geometry)) : min(fit, 1)
        // contentScale magnifies the zoomed-out layout back to the footprint.
        let metrics = FrameMetrics(arena: arena, scale: scale, contentScale: scale / geometry.zoom)
        appliedScale = metrics.contentScale
        isWindowFramed = true

        if geometry.isSplit {
            frameSplit(window: window, geometry: geometry, stage: stage, metrics: metrics)
        } else {
            frameSingle(window: window, geometry: geometry, metrics: metrics)
        }
    }

    private struct FrameMetrics {
        let arena: CGRect
        let scale: CGFloat
        let contentScale: CGFloat
    }

    private func frameSingle(window: UIWindow, geometry: DuoFrameGeometry, metrics: FrameMetrics) {
        let centre = CGPoint(x: metrics.arena.midX, y: metrics.arena.midY)
        let footprint = paneRect(size: geometry.size, scale: metrics.scale, centre: centre)
        setWindow(window, footprint: footprint, geometry: geometry, contentScale: metrics.contentScale)
        applySafeArea(target: geometry.safeAreaInsets.scaled(geometry.zoom), footprint: footprint, metrics: metrics)
        let bezel = backdrop.show(
            geometry: geometry, display: footprint, scale: metrics.scale, arena: metrics.arena,
            forced: settings.alwaysShowsBezel
        )
        chrome.show(
            outline: bezel == nil ? geometry.cornerRadii.scaled(metrics.scale).path(in: footprint) : nil,
            captionAnchor: bezel ?? footprint, caption: statusSummary(scale: metrics.contentScale),
            companion: nil, companionRadii: nil,
            reservedRegions: reservedRegionPaths(geometry: geometry, footprint: footprint, contentScale: metrics.contentScale)
        )
        updateBars(geometry: geometry, footprint: footprint, contentScale: metrics.contentScale)
    }

    private func frameSplit(window: UIWindow, geometry: DuoFrameGeometry, stage: CGSize, metrics: FrameMetrics) {
        let arena = metrics.arena
        let scale = metrics.scale
        let paneStep = (geometry.size.width + Self.splitGutter) * scale
        let stageOrigin = CGPoint(x: (arena.midX - stage.width * scale / 2), y: (arena.midY - stage.height * scale / 2))
        // Each app keeps its controls on its outer edge, so the app sits on the same side as its side controls.
        let appOnRight = geometry.sideEdge?.isRight ?? true
        let appCentreX = stageOrigin.x + (appOnRight ? paneStep : 0) + geometry.size.width * scale / 2
        let companionX = stageOrigin.x + (appOnRight ? 0 : paneStep)

        let appPane = paneRect(size: geometry.size, scale: scale, centre: CGPoint(x: appCentreX, y: arena.midY))
        setWindow(window, footprint: appPane, geometry: geometry, contentScale: metrics.contentScale)
        applySafeArea(target: geometry.safeAreaInsets.scaled(geometry.zoom), footprint: appPane, metrics: metrics)

        let companion = CGRect(
            x: companionX.rounded(), y: appPane.minY,
            width: (geometry.size.width * scale).rounded(), height: appPane.height
        )
        let companionRadii = DuoFrameCornerRadii
            .forPane(preset: geometry.preset, edge: geometry.sideEdge, isCompanion: true)
            .scaled(scale)
        let bezel = backdrop.show(
            geometry: geometry, display: appPane.union(companion), scale: scale, arena: arena,
            forced: settings.alwaysShowsBezel
        )
        chrome.show(
            outline: bezel == nil ? geometry.cornerRadii.scaled(scale).path(in: appPane) : nil,
            captionAnchor: bezel ?? appPane, caption: statusSummary(scale: metrics.contentScale),
            companion: companion, companionRadii: companionRadii,
            reservedRegions: reservedRegionPaths(geometry: geometry, footprint: appPane, contentScale: metrics.contentScale)
        )
        updateBars(geometry: geometry, footprint: appPane, contentScale: metrics.contentScale)
    }

    /// Paths, in chrome-window coordinates, for the reserved regions to stripe: the outer camera occlusion (positioned
    /// like the drawn cutout) and a full inner display's fold crease (a static guide, since the sim can't fold). Empty
    /// unless the overlay is switched on.
    private func reservedRegionPaths(geometry: DuoFrameGeometry, footprint: CGRect, contentScale: CGFloat) -> [CGPath] {
        guard settings.showsReservedRegions else { return [] }
        var paths: [CGPath] = []

        if let edge = geometry.sideEdge {
            let offset: CGFloat?
            switch cameraPlacement(for: geometry) {
            case .top: offset = footprint.minY + DuoFrameVerticalBar.cameraCentreOffset * contentScale
            case .bottom: offset = footprint.maxY - DuoFrameVerticalBar.cameraCentreOffset * contentScale
            case .hidden: offset = nil
            }
            if let centreY = offset {
                let diameter = DuoFrameVerticalBar.cameraDiameter * contentScale
                let inset = DuoFrameVerticalBar.columnInset * contentScale
                let centreX = edge.isRight ? footprint.maxX - inset : footprint.minX + inset
                let rect = CGRect(x: centreX - diameter / 2, y: centreY - diameter / 2, width: diameter, height: diameter)
                paths.append(CGPath(ellipseIn: rect, transform: nil))
            }
        }

        if let horizontal = geometry.preset.foldIsHorizontal {
            let band = DuoFrameInsets.foldBand * contentScale
            let rect = horizontal
                ? CGRect(x: footprint.minX, y: footprint.midY - band / 2, width: footprint.width, height: band)
                : CGRect(x: footprint.midX - band / 2, y: footprint.minY, width: band, height: footprint.height)
            paths.append(CGPath(rect: rect, transform: nil))
        }

        return paths
    }

    /// Sizes the app window to the footprint. The window's bounds are the (zoomed) layout size, a scale transform
    /// magnifies that to the on-screen footprint, and the mask rounds the device corners. Guarded against the layout
    /// pass that setting `bounds` triggers.
    private func setWindow(_ window: UIWindow, footprint: CGRect, geometry: DuoFrameGeometry, contentScale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: geometry.layoutSize)
        if window.bounds.size != geometry.layoutSize { window.bounds = bounds }
        window.transform = CGAffineTransform(scaleX: contentScale, y: contentScale)
        window.center = CGPoint(x: footprint.midX, y: footprint.midY)
        window.clipsToBounds = true
        window.layer.mask = windowMaskLayer
        setMask(windowMaskLayer, path: geometry.cornerRadii.scaled(geometry.zoom).path(in: bounds), frame: bounds)
    }

    /// Resets the app window to fill the scene with no transform or mask, when framing is switched off.
    private func resetWindow(_ window: UIWindow, to arena: CGRect) {
        if window.bounds.size != arena.size { window.bounds = CGRect(origin: .zero, size: arena.size) }
        window.transform = .identity
        window.center = CGPoint(x: arena.midX, y: arena.midY)
        window.layer.mask = nil
        window.clipsToBounds = false
    }

    /// The container reports zero safe area while framed, so the root's `additionalSafeAreaInsets` is the whole inset:
    /// the faked Duo value, raised to the host's real overlap only where the on-screen footprint still reaches a
    /// hardware region (a frame as large as, or larger than, the host over the notch). The host's real insets come
    /// from the full-screen chrome window, in screen points, so they're converted to the content's points by the
    /// content scale.
    /// Only a host whose insets are hardware (an iPhone's island and corners) pushes the content clear of them. An
    /// iPad's are software bars, so the frame keeps its own insets and the host bars hide or fade while overlapped.
    private func applySafeArea(target: UIEdgeInsets, footprint: CGRect, metrics: FrameMetrics) {
        let host = chromeWindow?.safeAreaInsets ?? .zero
        let honoursHost = UIDevice.current.userInterfaceIdiom.duoFrameHasHardwareInsets
        // Hiding the status bar zeroes the host's top inset, so keep the last one seen to judge the overlap by.
        if host.top > 0 { hostStatusBarInset = host.top }
        let hostTop = honoursHost ? host.top : hostStatusBarInset
        let arena = metrics.arena
        let scale = metrics.contentScale
        let overlap = UIEdgeInsets(
            top: max(0, hostTop - footprint.minY) / scale,
            left: max(0, host.left - footprint.minX) / scale,
            bottom: max(0, host.bottom - (arena.height - footprint.maxY)) / scale,
            right: max(0, host.right - (arena.width - footprint.maxX)) / scale
        )
        chrome.hidesHostStatusBar = !honoursHost && overlap.top > 0
        chrome.hidesHostHomeIndicator = !honoursHost && overlap.bottom > 0
        let counted = honoursHost ? overlap : .zero
        let additional = UIEdgeInsets(
            top: max(target.top, counted.top),
            left: max(target.left, counted.left),
            bottom: max(target.bottom, counted.bottom),
            right: max(target.right, counted.right)
        )
        if root.additionalSafeAreaInsets != additional {
            root.additionalSafeAreaInsets = additional
        }
        publishPresentationInsets(desired: additional)
    }

    /// A full-screen presentation can't be shielded, so it inherits the window's real insets. Hand it the shortfall up
    /// to the faked total, per edge — chiefly the side-controls strip, which the window reports nothing for.
    private func publishPresentationInsets(desired: UIEdgeInsets) {
        let host = view.safeAreaInsets
        DuoFramePresentationOverride.framedWindow = view.window
        DuoFramePresentationOverride.additionalInsets = UIEdgeInsets(
            top: max(0, desired.top - host.top),
            left: max(0, desired.left - host.left),
            bottom: max(0, desired.bottom - host.bottom),
            right: max(0, desired.right - host.right)
        )
    }

    /// The bar lives in the overlay chrome window, above the app window, so it stays visible over a full-screen
    /// presentation. It's laid out in the content's point space (bounds in layout points, so its internal metrics match
    /// the framed content), then scaled by the content scale and centred on the footprint's controls edge in screen
    /// points.
    /// Both stand-ins hide the same real tab bar, so the one leaving detaches (restoring it) before the other attaches.
    private func updateBars(geometry: DuoFrameGeometry, footprint: CGRect, contentScale: CGFloat) {
        let usesTabBar = geometry.preset.keepsHorizontalBars
        if !usesTabBar { tabBar.detach() }
        updateVerticalBar(geometry: geometry, footprint: footprint, contentScale: contentScale)
        if usesTabBar { tabBar.attach(to: root) }
        updateCornerStatus(geometry: geometry, footprint: footprint, contentScale: contentScale)
    }

    /// Where the bars stay horizontal, the status cluster sits in the top trailing corner, its ring centred as far in
    /// from both edges as the side strip's column is from its edge. Laid out in layout points, like the strip.
    private func updateCornerStatus(geometry: DuoFrameGeometry, footprint: CGRect, contentScale: CGFloat) {
        guard geometry.preset.keepsHorizontalBars else {
            cornerStatus.removeFromSuperview()
            return
        }
        if cornerStatus.superview !== chrome.view {
            chrome.view.insertSubview(cornerStatus, at: 0)
        }
        cornerStatus.sampledView = view.window
        cornerStatus.setColourAdaptation(settings.adaptsStatusColours)
        cornerStatus.transform = .identity
        cornerStatus.bounds = CGRect(origin: .zero, size: geometry.layoutSize)
        cornerStatus.transform = CGAffineTransform(scaleX: contentScale, y: contentScale)
        cornerStatus.center = CGPoint(x: footprint.midX, y: footprint.midY)
        let inset = DuoFrameVerticalBar.columnInset
        cornerStatus.place(ring: CGPoint(x: geometry.layoutSize.width - inset, y: inset), axis: .horizontal)
    }

    private func updateVerticalBar(geometry: DuoFrameGeometry, footprint: CGRect, contentScale: CGFloat) {
        guard let edge = geometry.sideEdge else {
            verticalBar.detach()
            return
        }
        if verticalBar.superview == nil {
            verticalBar.attach(to: root, in: chrome.view)
        }
        verticalBar.isOnRightEdge = edge.isRight
        verticalBar.setColourAdaptation(settings.adaptsStatusColours)
        verticalBar.transform = .identity
        verticalBar.bounds = CGRect(x: 0, y: 0, width: DuoFrameVerticalBar.width, height: geometry.layoutSize.height)
        verticalBar.transform = CGAffineTransform(scaleX: contentScale, y: contentScale)
        let stripWidth = DuoFrameVerticalBar.width * contentScale
        let centreX = edge.isRight ? footprint.maxX - stripWidth / 2 : footprint.minX + stripWidth / 2
        verticalBar.center = CGPoint(x: centreX, y: footprint.midY)
    }

    private func paneRect(size: CGSize, scale: CGFloat, centre: CGPoint) -> CGRect {
        CGRect(
            x: (centre.x - size.width * scale / 2).rounded(),
            y: (centre.y - size.height * scale / 2).rounded(),
            width: size.width * scale, height: size.height * scale
        )
    }

    /// Updates a shape layer's path and frame without the implicit animation a layout pass would otherwise trigger.
    private func setMask(_ layer: CAShapeLayer, path: CGPath, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.path = path
        CATransaction.commit()
    }

    /// Host points per inch over the simulated device's, so one of its points renders at its real physical size.
    /// Host: iPad mini 163, other iPads 132, 3x iPhones ≈153.
    private func physicalScale(for geometry: DuoFrameGeometry) -> CGFloat {
        guard let screen = view.window?.windowScene?.screen else { return 1 }
        let hostPointsPerInch: CGFloat
        switch traitCollection.userInterfaceIdiom {
        case .pad:
            hostPointsPerInch = screen.nativeBounds.size == CGSize(width: 1_488, height: 2_266) ? 163 : 132
        case .phone:
            hostPointsPerInch = DuoFrameScreenOverride.hostNativeScale(of: screen) >= 3 ? 153 : 163
        default:
            hostPointsPerInch = 153
        }
        return hostPointsPerInch / geometry.pointsPerInch
    }

    // MARK: - Status

    func statusSummary(scale: CGFloat? = nil) -> String {
        guard let geometry = settings.geometry else {
            let bounds = view.window?.windowScene?.coordinateSpace.bounds ?? .zero
            return "Framing off · host \(Int(bounds.width))×\(Int(bounds.height)) pt"
        }
        let traits = root.traitCollection
        let insets = geometry.safeAreaInsets
        var parts = [
            "\(Int(geometry.size.width))×\(Int(geometry.size.height)) pt",
            "\(traits.horizontalSizeClass.letter)×\(traits.verticalSizeClass.letter)",
            "safe t\(Int(insets.top)) l\(Int(insets.left)) b\(Int(insets.bottom)) r\(Int(insets.right))"
        ]
        if geometry.zoom != 1 {
            let layout = geometry.layoutSize
            parts.append("zoom \(Int(layout.width.rounded()))×\(Int(layout.height.rounded())) pt")
        }
        let shownScale = scale ?? appliedScale
        if abs(shownScale - 1) > 0.005 {
            parts.append("×\(String(format: "%.2f", shownScale))")
        }
        return parts.joined(separator: "  ")
    }

    // MARK: - Custom size

    func promptForCustomSize() {
        let alert = UIAlertController(
            title: "Custom frame size",
            message: "Width × height in points",
            preferredStyle: .alert
        )
        let current = settings.customSize
        alert.addTextField { field in
            field.placeholder = "Width"
            field.keyboardType = .numberPad
            field.text = String(Int(current.width))
        }
        alert.addTextField { field in
            field.placeholder = "Height"
            field.keyboardType = .numberPad
            field.text = String(Int(current.height))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, fields.count == 2,
                  let width = Double(fields[0].text ?? ""), let height = Double(fields[1].text ?? ""),
                  width >= 100, height >= 100 else { return }
            let size = CGSize(width: width, height: height)
            settings.customSize = size
            settings.otherDevice = DuoDevice.custom(size)
            settings.preset = .otherDevice
        })
        (chromeWindow?.rootViewController ?? self).present(alert, animated: true)
    }
}

/// The debug chrome, hosted in the passthrough window above the app window. Draws the frame outline, the status
/// caption, the split-view companion pane and the menu button. Everything but the button is non-interactive so touches
/// fall through to the app.
private final class DuoFrameChromeViewController: UIViewController {

    private let outlineLayer = CAShapeLayer()
    private let caption = UILabel()
    private let companion = DuoFrameCompanionView()
    private let companionMaskLayer = CAShapeLayer()
    private let reservedRegionsView = DuoFrameReservedRegionsView()
    private let menuButton: DuoFrameMenuButton
    private let noticeButton = UIButton(configuration: .noticeStyle)
    var onSafeAreaChange: (() -> Void)?

    /// Shown until tapped; setting it again (even to the same text) re-shows it.
    var notice: String? {
        didSet {
            noticeButton.configuration?.title = notice
            noticeButton.isHidden = notice == nil
        }
    }

    /// The app-window status-bar root. This overlay sits in a window above the app, so it would otherwise govern the
    /// status bar and home indicator itself and impose its defaults (revealing a bar an app hides). Mirroring the app
    /// root's resolved preferences keeps the host in charge.
    weak var appearanceSource: UIViewController?

    init(menuButton: DuoFrameMenuButton) {
        self.menuButton = menuButton
        super.init(nibName: nil, bundle: nil)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        onSafeAreaChange?()
    }

    var hidesHostStatusBar = false {
        didSet {
            guard hidesHostStatusBar != oldValue else { return }
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    var hidesHostHomeIndicator = false {
        didSet {
            guard hidesHostHomeIndicator != oldValue else { return }
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    override var prefersStatusBarHidden: Bool {
        hidesHostStatusBar
            || appearanceLeaf(\.childForStatusBarHidden)?.prefersStatusBarHidden ?? super.prefersStatusBarHidden
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        appearanceLeaf(\.childForStatusBarStyle)?.preferredStatusBarStyle ?? super.preferredStatusBarStyle
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        hidesHostHomeIndicator
            || appearanceLeaf(\.childForHomeIndicatorAutoHidden)?.prefersHomeIndicatorAutoHidden
            ?? super.prefersHomeIndicatorAutoHidden
    }

    /// Follows the app root's `childFor…` chain to the controller that actually decides. Cross-window child forwarding
    /// isn't valid (a `childFor…` child must share the containment hierarchy), so the leaf is resolved by hand.
    private func appearanceLeaf(_ child: KeyPath<UIViewController, UIViewController?>) -> UIViewController? {
        guard var current = appearanceSource else { return nil }
        while let next = current[keyPath: child] { current = next }
        return current
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameChromeViewController is created in code only")
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        companion.isHidden = true
        companion.isUserInteractionEnabled = false
        companion.layer.mask = companionMaskLayer
        view.addSubview(companion)

        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.lineWidth = 1
        outlineLayer.isHidden = true
        view.layer.addSublayer(outlineLayer)

        caption.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.isUserInteractionEnabled = false
        view.addSubview(caption)

        reservedRegionsView.frame = view.bounds
        view.addSubview(reservedRegionsView)

        noticeButton.isHidden = notice == nil
        noticeButton.addAction(
            UIAction { [weak self] _ in self?.noticeButton.isHidden = true }, for: .primaryActionTriggered
        )
        view.addSubview(noticeButton)
        noticeButton.translatesAutoresizingMaskIntoConstraints = false
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            noticeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            noticeButton.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            noticeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            noticeButton.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 16)
        ])

        // The button positions itself (draggable, edge-snapped, persisted), so it manages its own frame. Added last so
        // it stays above the reserved-region overlay and the notice.
        menuButton.isHidden = !DuoFrameSimulator.showsButtonByDefault
        view.addSubview(menuButton)

        updateOutlineColour()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateOutlineColour()
        }
    }

    private func updateOutlineColour() {
        outlineLayer.strokeColor = UIColor.label.withAlphaComponent(0.3).resolvedColor(with: traitCollection).cgColor
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        menuButton.applyStoredPosition()
    }

    /// Framing off: hide everything but the menu button.
    func clear() {
        outlineLayer.isHidden = true
        caption.isHidden = true
        companion.isHidden = true
        reservedRegionsView.regions = []
    }

    /// `outline` is `nil` where the device bezel already marks the frame's edge; the caption goes by `captionAnchor`.
    func show(
        outline: CGPath?,
        captionAnchor: CGRect,
        caption text: String,
        companion companionRect: CGRect?,
        companionRadii: DuoFrameCornerRadii?,
        reservedRegions: [CGPath]
    ) {
        loadViewIfNeeded()
        if let outline { setMask(outlineLayer, path: outline, frame: view.bounds) }
        outlineLayer.isHidden = outline == nil
        layoutCaption(text: text, footprint: captionAnchor)
        reservedRegionsView.frame = view.bounds
        reservedRegionsView.regions = reservedRegions
        if let companionRect, let companionRadii {
            companion.frame = companionRect
            setMask(companionMaskLayer, path: companionRadii.path(in: companion.bounds), frame: companion.bounds)
            companion.isHidden = false
        } else {
            companion.isHidden = true
        }
    }

    private func layoutCaption(text: String, footprint: CGRect) {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        caption.text = text
        caption.sizeToFit()
        let height = caption.bounds.height
        let below = footprint.maxY + 6
        let above = footprint.minY - 6 - height
        if below + height <= safe.maxY {
            caption.frame.origin.y = below
        } else if above >= safe.minY {
            caption.frame.origin.y = above
        } else {
            caption.isHidden = true
            return
        }
        caption.isHidden = false
        caption.frame.origin.x = (footprint.midX - caption.bounds.width / 2).rounded()
    }

    private func setMask(_ layer: CAShapeLayer, path: CGPath, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.path = path
        CATransaction.commit()
    }
}

/// Zeroes the safe area the hosted root inherits. Its own view is pinned inside the parent's safe area, so it inherits
/// nothing (a view cannot report less safe area than it inherits, and `additionalSafeAreaInsets` only adds); the hosted
/// content is then held overhanging this view to fill the whole frame, taking its safe area entirely from the parent's
/// `additionalSafeAreaInsets`.
private final class DuoFrameShieldViewController: UIViewController {

    let content: UIViewController

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameShieldViewController is created in code only")
    }

    override func loadView() {
        view = DuoFrameShieldView()
        view.backgroundColor = .clear
        view.clipsToBounds = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.autoresizingMask = []
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Overhang the shield to cover the whole frame; the shield's inset only governs the inherited safe area.
        if let parent = view.superview {
            content.view.frame = view.convert(parent.bounds, from: parent)
        }
    }

    override var childForStatusBarStyle: UIViewController? { content }
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { content.supportedInterfaceOrientations }
}

/// Reports a point as inside when any subview (the overhanging content) contains it, so touches in the region the
/// content extends beyond this view's own bounds still reach it.
private final class DuoFrameShieldView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { $0.point(inside: convert(point, to: $0), with: event) }
    }
}

/// Passes every touch that doesn't land on an interactive subview (the menu button) down to the window beneath it —
/// except while the menu is open, when it keeps an outside tap so UIKit's own dismissal can fire instead of the tap
/// reaching the app.
private final class DuoFramePassthroughWindow: UIWindow {
    var isMenuOpen: () -> Bool = { false }
    var onOutsideTapWhileMenuOpen: () -> Void = {}

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard hit === rootViewController?.view else { return hit }
        guard isMenuOpen() else { return nil }
        onOutsideTapWhileMenuOpen()
        return hit
    }
}

private extension UIViewController {
    var tabBarControllersInTree: [UITabBarController] {
        let own = (self as? UITabBarController).map { [$0] } ?? []
        return own + children.flatMap(\.tabBarControllersInTree)
    }
}

private extension UIButton.Configuration {
    static var noticeStyle: Self {
        var config = Self.filled()
        config.baseBackgroundColor = .systemYellow
        config.baseForegroundColor = .black
        config.cornerStyle = .large
        config.titleAlignment = .center
        config.titleLineBreakMode = .byWordWrapping
        config.subtitle = "Tap to dismiss"
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        return config
    }
}

private extension UIUserInterfaceIdiom {
    var duoFrameHasHardwareInsets: Bool {
        switch self {
        case .phone: true
        case .pad, .mac, .tv, .carPlay, .vision, .unspecified: false
        @unknown default: false
        }
    }
}

private extension UIUserInterfaceSizeClass {
    var letter: String {
        switch self {
        case .compact: "C"
        case .regular: "R"
        case .unspecified: "?"
        @unknown default: "?"
        }
    }
}

private extension UIEdgeInsets {
    func scaled(_ factor: CGFloat) -> UIEdgeInsets {
        UIEdgeInsets(top: top * factor, left: left * factor, bottom: bottom * factor, right: right * factor)
    }
}
#endif
