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
/// window above the app window.
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
    private let shield: DuoFrameShieldViewController
    private var chromeWindow: UIWindow?
    private var appliedScale: CGFloat = 1
    private var hasAppliedScreenOverrides = false
    private var isFramingWindow = false

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
        applyTraitOverrides()
        applyScreenOverrides()
        verticalBar.cameraPlacement = cameraPlacement(for: settings.geometry)
        if settings.simulatesVerticalBars, settings.geometry?.sideEdge != nil {
            verticalBar.attach(to: root)
        } else {
            verticalBar.detach()
        }
        frameWindow()
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
        if settings.geometry != nil, settings.reportsPhoneIdiom {
            root.traitOverrides.userInterfaceIdiom = .phone
        } else {
            root.traitOverrides.remove(UITraitUserInterfaceIdiom.self)
        }
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

    private func ensureChromeWindow() {
        guard chromeWindow == nil, let scene = view.window?.windowScene else { return }
        let window = DuoFramePassthroughWindow(windowScene: scene)
        // Above the app window so the menu button is reachable even when the frame fills the screen; the passthrough
        // window forwards every touch that misses the button down to the app window.
        window.windowLevel = .normal + 1
        // Full screen: its safe area is the host's real device insets, the source for the framed root's overlap.
        chrome.onSafeAreaChange = { [weak self] in self?.frameWindow() }
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

        // The real screen, read past the UIScreen.bounds override so the arena is always the true host size.
        let arena = DuoFrameScreenOverride.hostBounds(of: scene.screen)
        guard let geometry = settings.geometry else {
            // Off: the shield still zeroes what the root inherits, so hand it the host's real insets to reproduce
            // normal behaviour.
            resetWindow(window, to: arena)
            let host = view.safeAreaInsets
            if root.additionalSafeAreaInsets != host { root.additionalSafeAreaInsets = host }
            DuoFramePresentationOverride.framedWindow = nil
            chrome.clear()
            verticalBar.isHidden = true
            appliedScale = 1
            return
        }

        // A split pose lays the app and a companion pane across a full-inner-display stage; every other pose fills
        // its own footprint. Both share the fit-scale maths. Fit is to the whole screen: a frame the size of the
        // screen renders 1:1, a smaller one at true point size centred, only a larger one scales below 1.
        let stage = geometry.isSplit
            ? CGSize(width: geometry.size.width * 2 + Self.splitGutter, height: geometry.size.height)
            : geometry.size
        let fit = min(arena.width / stage.width, arena.height / stage.height)
        let scale = settings.matchesPhysicalDensity ? min(fit, physicalScale(for: geometry)) : min(fit, 1)
        // contentScale magnifies the zoomed-out layout back to the footprint.
        let metrics = FrameMetrics(arena: arena, scale: scale, contentScale: scale / geometry.zoom)
        appliedScale = metrics.contentScale

        if geometry.isSplit {
            frameSplit(window: window, geometry: geometry, stage: stage, metrics: metrics)
        } else {
            frameSingle(window: window, geometry: geometry, metrics: metrics)
        }
        verticalBar.isHidden = false
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
        chrome.show(
            outline: footprint, radii: geometry.cornerRadii.scaled(metrics.scale),
            caption: statusSummary(scale: metrics.contentScale), companion: nil, companionRadii: nil
        )
        verticalBar.frame = verticalBarStrip(for: geometry)
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
        chrome.show(
            outline: appPane, radii: geometry.cornerRadii.scaled(scale),
            caption: statusSummary(scale: metrics.contentScale), companion: companion, companionRadii: companionRadii
        )
        verticalBar.frame = verticalBarStrip(for: geometry)
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

    /// Resets the app window to fill the screen with no transform or mask, for the framing-off state.
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
    private func applySafeArea(target: UIEdgeInsets, footprint: CGRect, metrics: FrameMetrics) {
        let host = chromeWindow?.safeAreaInsets ?? .zero
        let arena = metrics.arena
        let scale = metrics.contentScale
        let overlap = UIEdgeInsets(
            top: max(0, host.top - footprint.minY) / scale,
            left: max(0, host.left - footprint.minX) / scale,
            bottom: max(0, host.bottom - (arena.height - footprint.maxY)) / scale,
            right: max(0, host.right - (arena.width - footprint.maxX)) / scale
        )
        let additional = UIEdgeInsets(
            top: max(target.top, overlap.top),
            left: max(target.left, overlap.left),
            bottom: max(target.bottom, overlap.bottom),
            right: max(target.right, overlap.right)
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

    /// The bar is a child of `root.view`, so it works in that view's point space — which is the Display-Zoom layout
    /// size (the window's bounds), not the nominal device size.
    private func verticalBarStrip(for geometry: DuoFrameGeometry) -> CGRect {
        guard let edge = geometry.sideEdge else { return .zero }
        let bounds = root.view.bounds
        return CGRect(
            x: edge.isRight ? bounds.width - DuoFrameVerticalBar.width : 0,
            y: 0,
            width: DuoFrameVerticalBar.width,
            height: bounds.height
        )
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
            let arena = view.window?.windowScene?.screen ?? UIScreen.main
            let bounds = DuoFrameScreenOverride.hostBounds(of: arena)
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
    private let menuButton: DuoFrameMenuButton
    var onSafeAreaChange: (() -> Void)?

    init(menuButton: DuoFrameMenuButton) {
        self.menuButton = menuButton
        super.init(nibName: nil, bundle: nil)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        onSafeAreaChange?()
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
        outlineLayer.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        outlineLayer.lineWidth = 1
        outlineLayer.isHidden = true
        view.layer.addSublayer(outlineLayer)

        caption.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        caption.textColor = .white.withAlphaComponent(0.7)
        caption.textAlignment = .center
        caption.isUserInteractionEnabled = false
        view.addSubview(caption)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.isHidden = !DuoFrameSimulator.showsButtonByDefault
        view.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)
        ])
    }

    /// Framing off: hide everything but the menu button.
    func clear() {
        outlineLayer.isHidden = true
        caption.isHidden = true
        companion.isHidden = true
    }

    func show(
        outline: CGRect,
        radii: DuoFrameCornerRadii,
        caption text: String,
        companion companionRect: CGRect?,
        companionRadii: DuoFrameCornerRadii?
    ) {
        loadViewIfNeeded()
        setMask(outlineLayer, path: radii.path(in: outline), frame: view.bounds)
        outlineLayer.isHidden = false
        layoutCaption(text: text, footprint: outline)
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

/// Passes every touch that doesn't land on an interactive subview (the menu button) down to the window beneath it.
private final class DuoFramePassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === rootViewController?.view ? nil : hit
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
