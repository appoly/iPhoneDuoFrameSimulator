//
//  DuoFrameViewController.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

/// Hosts the app's real root as a child pinned to a Duo display size, with that display's size classes and a
/// guessed safe area, scaled to fit the host window. Frame changes resize the child live, like a fold would.
final class DuoFrameViewController: UIViewController {

    let root: UIViewController

    var settings: DuoFrameSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            apply()
        }
    }

    private let outlineLayer = CAShapeLayer()
    private let rootMaskLayer = CAShapeLayer()
    private let companionMaskLayer = CAShapeLayer()
    private let caption = UILabel()
    private let shield: DuoFrameShieldViewController
    private var frameView: UIView { shield.frameView }
    private let verticalBar = DuoFrameVerticalBar()
    private let companion = DuoFrameCompanionView()
    private lazy var menuButton = DuoFrameMenuButton(controller: self)
    private var appliedScale: CGFloat = 1
    private var hasAppliedScreenOverrides = false

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

        addChild(shield)
        view.addSubview(shield.view)
        shield.didMove(toParent: self)

        companion.isHidden = true
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
        view.addSubview(caption)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.isHidden = !DuoFrameSimulator.showsButtonByDefault
        view.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)
        ])

        apply()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        layoutRoot()
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
        view.setNeedsLayout()
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

    // MARK: - Layout

    private func layoutRoot() {
        shield.view.frame = view.safeAreaLayoutGuide.layoutFrame
        guard let geometry = settings.geometry else {
            frameView.transform = .identity
            frameView.frame = view.convert(view.bounds, to: shield.view)
            frameView.clipsToBounds = false
            frameView.layer.mask = nil
            // The shield inherits nothing even when framing is off, so the host's real insets are supplied here.
            if root.additionalSafeAreaInsets != view.safeAreaInsets {
                root.additionalSafeAreaInsets = view.safeAreaInsets
            }
            outlineLayer.isHidden = true
            caption.isHidden = true
            verticalBar.isHidden = true
            companion.isHidden = true
            return
        }
        // A split pose lays the app and a companion pane across a full-inner-display stage; every other pose fills its
        // own footprint. Both share the fit-scale maths.
        let stage = geometry.isSplit
            ? CGSize(width: geometry.size.width * 2 + Self.splitGutter, height: geometry.size.height)
            : geometry.size
        // Fit to the whole physical screen, not the host's safe area, so a frame the same size as (or smaller than)
        // the real screen renders at true point size — full-screen at a 1:1 match, centred with a border when smaller.
        // Only a frame larger than the screen scales below 1.
        let arena = view.bounds
        let fit = min(arena.width / stage.width, arena.height / stage.height)
        let scale = settings.matchesPhysicalDensity ? min(fit, physicalScale(for: geometry)) : min(fit, 1)
        appliedScale = scale / geometry.zoom   // the scale actually applied to the content, magnified by Display Zoom

        if geometry.isSplit {
            layoutSplit(geometry: geometry, arena: arena, stage: stage, scale: scale)
        } else {
            layoutSingle(geometry: geometry, arena: arena, scale: scale)
        }
    }

    private func layoutSingle(geometry: DuoFrameGeometry, arena: CGRect, scale: CGFloat) {
        let footprint = paneRect(size: geometry.size, scale: scale, centre: CGPoint(x: arena.midX, y: arena.midY))
        let contentScale = scale / geometry.zoom
        placeRoot(in: footprint, geometry: geometry, contentScale: contentScale)
        let insets = geometry.safeAreaInsets.scaled(geometry.zoom)
        applyFakedSafeArea(target: insets, footprint: footprint, scale: contentScale)
        companion.isHidden = true
        setOutline(rect: footprint, radii: geometry.cornerRadii.scaled(scale))
        layoutCaption(scale: contentScale, footprint: footprint)
        verticalBar.frame = verticalBarStrip(for: geometry)
    }

    private func layoutSplit(geometry: DuoFrameGeometry, arena: CGRect, stage: CGSize, scale: CGFloat) {
        let paneStep = (geometry.size.width + Self.splitGutter) * scale
        let stageOrigin = CGPoint(x: (arena.midX - stage.width * scale / 2), y: (arena.midY - stage.height * scale / 2))
        // Each app keeps its controls on its outer edge, so the app sits on the same side as its side controls.
        let appOnRight = geometry.sideEdge?.isRight ?? true
        let appCentreX = stageOrigin.x + (appOnRight ? paneStep : 0) + geometry.size.width * scale / 2
        let companionX = stageOrigin.x + (appOnRight ? 0 : paneStep)

        let appPane = paneRect(size: geometry.size, scale: scale, centre: CGPoint(x: appCentreX, y: arena.midY))
        let contentScale = scale / geometry.zoom
        placeRoot(in: appPane, geometry: geometry, contentScale: contentScale)
        let appInsets = geometry.safeAreaInsets.scaled(geometry.zoom)
        applyFakedSafeArea(target: appInsets, footprint: appPane, scale: contentScale)

        companion.frame = CGRect(
            x: companionX.rounded(), y: appPane.minY,
            width: (geometry.size.width * scale).rounded(), height: appPane.height
        )
        let companionRadii = DuoFrameCornerRadii
            .forPane(preset: geometry.preset, edge: geometry.sideEdge, isCompanion: true)
            .scaled(scale)
        setMask(companionMaskLayer, path: companionRadii.path(in: companion.bounds), frame: companion.bounds)
        companion.isHidden = false

        setOutline(rect: appPane, radii: geometry.cornerRadii.scaled(scale))
        layoutCaption(scale: contentScale, footprint: appPane)
        verticalBar.frame = verticalBarStrip(for: geometry)
    }

    /// A shape-layer stroke around the app pane. Its path lives in the container's coordinate space, so its frame
    /// spans the whole view and the footprint rect maps straight through.
    private func setOutline(rect: CGRect, radii: DuoFrameCornerRadii) {
        setMask(outlineLayer, path: radii.path(in: rect), frame: view.bounds)
        outlineLayer.isHidden = false
    }

    /// Updates a shape layer's path and frame without the implicit animation a layout pass would otherwise trigger.
    private func setMask(_ layer: CAShapeLayer, path: CGPath, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.path = path
        CATransaction.commit()
    }

    private func paneRect(size: CGSize, scale: CGFloat, centre: CGPoint) -> CGRect {
        CGRect(
            x: (centre.x - size.width * scale / 2).rounded(),
            y: (centre.y - size.height * scale / 2).rounded(),
            width: size.width * scale, height: size.height * scale
        )
    }

    private func placeRoot(in footprint: CGRect, geometry: DuoFrameGeometry, contentScale: CGFloat) {
        // Display Zoom lays the app out at the smaller layout size; the compensating content scale magnifies it back
        // to the same footprint. Corners are scaled by zoom too so they still render at the physical radius
        // (× zoom × contentScale == × the fit scale).
        frameView.bounds = CGRect(origin: .zero, size: geometry.layoutSize)
        frameView.transform = CGAffineTransform(scaleX: contentScale, y: contentScale)
        frameView.center = view.convert(CGPoint(x: footprint.midX, y: footprint.midY), to: shield.view)
        frameView.clipsToBounds = true
        frameView.layer.mask = rootMaskLayer
        let radii = geometry.cornerRadii.scaled(geometry.zoom)
        setMask(rootMaskLayer, path: radii.path(in: frameView.bounds), frame: frameView.bounds)
    }

    /// The hosted root sees the faked `target`, or the host's real inset where the hardware needs more (its island
    /// still overlaps the content). The shield leaves it inheriting nothing, so this is the whole amount. Values are in
    /// the root's own points, so the real overlap is un-scaled by the fit scale.
    private func applyFakedSafeArea(target: UIEdgeInsets, footprint: CGRect, scale: CGFloat) {
        let host = view.safeAreaInsets
        let insets = UIEdgeInsets(
            top: max(target.top, max(0, host.top - footprint.minY) / scale),
            left: max(target.left, max(0, host.left - footprint.minX) / scale),
            bottom: max(target.bottom, max(0, host.bottom - (view.bounds.height - footprint.maxY)) / scale),
            right: max(target.right, max(0, host.right - (view.bounds.width - footprint.maxX)) / scale)
        )
        if root.additionalSafeAreaInsets != insets {
            root.additionalSafeAreaInsets = insets
        }
    }

    /// The bar is a child of `root.view`, so it works in that view's point space — which is the Display-Zoom layout
    /// size, not the nominal device size.
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

    private func layoutCaption(scale: CGFloat, footprint: CGRect) {
        // The frame fits the full screen, but the caption is debug chrome, so it stays inside the host's safe area.
        let safe = view.safeAreaLayoutGuide.layoutFrame
        caption.text = statusSummary(scale: scale)
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
            return "Framing off · host \(Int(view.bounds.width))×\(Int(view.bounds.height)) pt"
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
        topmostPresenter.present(alert, animated: true)
    }

    private var topmostPresenter: UIViewController {
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        return presenter
    }
}

/// Hosts the content with its view pinned inside the host's safe area, so the content inherits none of it and
/// `additionalSafeAreaInsets` is the whole story. UIKit derives a controller view's safe area from the nearest
/// ancestor controller's view (a transformed one gets the host's overlap un-scaled, or nothing at all if the
/// controller's own view is transformed) and ignores a negative `additionalSafeAreaInsets`, so this is the only way
/// to hand the content less than the host's own inset. `frameView` carries the fit/zoom transform and corner mask
/// and overhangs the shield; touches pass through to it.
private final class DuoFrameShieldViewController: UIViewController {

    let content: UIViewController
    let frameView = UIView()

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
        view.clipsToBounds = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(frameView)
        addChild(content)
        content.view.frame = frameView.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        frameView.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override var childForStatusBarStyle: UIViewController? { content }
    override var childForStatusBarHidden: UIViewController? { content }
    override var childForHomeIndicatorAutoHidden: UIViewController? { content }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { content }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { content.supportedInterfaceOrientations }
}

private final class DuoFrameShieldView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { $0.point(inside: convert(point, to: $0), with: event) }
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
