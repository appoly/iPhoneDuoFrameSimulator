//
//  DuoFrameSettings.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

enum DuoFramePreset: String, Codable, CaseIterable {
    case off
    case outerLandscape
    case outerPortrait
    case innerLandscape
    case innerPortrait
    case innerSplitHalf
    /// A phone form factor or custom size; its size and look come from `DuoFrameSettings.otherDevice`.
    case otherDevice

    var title: String {
        switch self {
        case .off: "Off"
        case .outerLandscape: "Duo Outer · Landscape"
        case .outerPortrait: "Duo Outer · Portrait"
        case .innerLandscape: "Duo Inner · Landscape"
        case .innerPortrait: "Duo Inner · Portrait"
        case .innerSplitHalf: "Duo Inner · Split View"
        case .otherDevice: "Other sizes…"
        }
    }

    // Measured on the 27.1 Duo simulator. A Split View half is (951 − gutter) / 2.
    func size(custom: CGSize) -> CGSize? {
        switch self {
        case .off, .otherDevice: nil
        case .outerLandscape: CGSize(width: 678, height: 466)
        case .outerPortrait: CGSize(width: 466, height: 678)
        case .innerLandscape: CGSize(width: 951, height: 669)
        case .innerPortrait: CGSize(width: 669, height: 951)
        case .innerSplitHalf: CGSize(width: 469, height: 669)
        }
    }

    /// Every Duo pose except inner-display portrait puts the status bar and controls along a side edge.
    func usesSideControls(for size: CGSize) -> Bool {
        switch self {
        case .off, .innerPortrait, .otherDevice: false
        case .outerLandscape, .outerPortrait, .innerLandscape, .innerSplitHalf: true
        }
    }

    var keepsHorizontalBars: Bool {
        switch self {
        case .innerPortrait: true
        case .off, .outerLandscape, .outerPortrait, .innerLandscape, .innerSplitHalf, .otherDevice: false
        }
    }

    /// True where the pose shares the inner display with a second app, so the tool draws a companion pane.
    var isSplit: Bool {
        switch self {
        case .innerSplitHalf: true
        case .off, .outerLandscape, .outerPortrait, .innerLandscape, .innerPortrait, .otherDevice: false
        }
    }

    /// Whether a full inner display's fold crease runs horizontally (the tall pose) or vertically (the wide one), or
    /// `nil` where the tool models no fold guide (outer displays, split panes, other devices).
    var foldIsHorizontal: Bool? {
        switch self {
        case .innerPortrait: true
        case .innerLandscape: false
        case .off, .outerLandscape, .outerPortrait, .innerSplitHalf, .otherDevice: nil
        }
    }

    // Split View halves' size classes are unpublished; compact width follows the iPad precedent.
    func sizeClasses(for size: CGSize) -> (horizontal: UIUserInterfaceSizeClass, vertical: UIUserInterfaceSizeClass) {
        switch self {
        case .off, .otherDevice: (.unspecified, .unspecified)
        case .outerLandscape: (.compact, .compact)
        case .outerPortrait, .innerSplitHalf: (.compact, .regular)
        case .innerLandscape, .innerPortrait: (.regular, .regular)
        }
    }
}

enum DuoFrameSideEdge: String, Codable, CaseIterable {
    case right
    case left
    case off

    var title: String {
        switch self {
        case .right: "Right edge"
        case .left: "Left edge"
        case .off: "No side controls"
        }
    }

    var isRight: Bool {
        switch self {
        case .right: true
        case .left, .off: false
        }
    }

    var activeEdge: DuoFrameSideEdge? {
        switch self {
        case .right, .left: self
        case .off: nil
        }
    }

    var sideControlsInsets: UIEdgeInsets {
        switch self {
        case .right:
            UIEdgeInsets(
                top: 0, left: 0, bottom: DuoFrameInsets.sideControlsHomeIndicator, right: DuoFrameInsets.sideControls
            )
        case .left:
            UIEdgeInsets(
                top: 0, left: DuoFrameInsets.sideControls, bottom: DuoFrameInsets.sideControlsHomeIndicator, right: 0
            )
        case .off:
            UIEdgeInsets(top: 0, left: 0, bottom: DuoFrameInsets.sideControlsHomeIndicator, right: 0)
        }
    }
}

/// Measured on the 27.1 Duo simulator. The side inset equals the drawn strip width so app content (and its scroll
/// indicators) always clears the controls region.
enum DuoFrameInsets {
    static let sideControls = DuoFrameVerticalBar.width
    static let sideControlsHomeIndicator: CGFloat = 34
    static let portraitStatusBar: CGFloat = 82
    static let portraitHomeIndicator: CGFloat = 34
    /// The fold division band's thickness (measured partially folded on the 27.1 Duo simulator).
    static let foldBand: CGFloat = 40

    static let portrait = UIEdgeInsets(top: portraitStatusBar, left: 0, bottom: portraitHomeIndicator, right: 0)
}

struct DuoFrameGeometry: Equatable {
    let preset: DuoFramePreset
    let size: CGSize
    let horizontalSizeClass: UIUserInterfaceSizeClass
    let verticalSizeClass: UIUserInterfaceSizeClass
    let sideEdge: DuoFrameSideEdge?
    let safeAreaInsets: UIEdgeInsets
    let isSplit: Bool
    let cornerRadii: DuoFrameCornerRadii
    /// Display Zoom: `UIScreen.scale / nativeScale`. The app lays out at `layoutSize` (fewer points, larger UI)
    /// while keeping the footprint, so the content is magnified. 1 when off.
    let zoom: CGFloat
    /// The simulated device's physical density, the target for "Match physical size".
    let pointsPerInch: CGFloat

    var layoutSize: CGSize {
        CGSize(width: size.width * zoom, height: size.height * zoom)
    }

    /// What `UIScreen.bounds` reports on the device: the whole display, which a Split View half only shares.
    var screenLayoutSize: CGSize {
        let display = isSplit ? DuoFramePreset.innerLandscape.size(custom: size) ?? size : size
        return CGSize(width: display.width * zoom, height: display.height * zoom)
    }
}

struct DuoFrameSettings: Codable, Equatable {
    var preset = DuoFramePreset.off
    var customSize = CGSize(width: 800, height: 600)
    var otherDevice = DuoDevice.defaultOther
    var sideEdge = DuoFrameSideEdge.right
    var overridesSizeClasses = true
    var matchesPhysicalDensity = false
    /// Draws the device bezel even where it doesn't fit around the frame, shrinking the frame to make room. Off by
    /// default: the bezel then only appears where there's space for it at the frame's own scale.
    var alwaysShowsBezel = false
    /// Whether the side strip's clock and network glyphs sample the content beneath them to flip black/white. Each
    /// sample re-renders the app content, so it carries a recurring CPU cost; off by default, and the glyphs then
    /// stay `.label`.
    var adaptsStatusColours = false
    var displayZoom = false
    /// Reports the simulated display's size from `UIScreen.bounds` (the whole display in Split View) while framing, as
    /// the device would, so layout sized from `UIScreen.main` shows how it behaves there. Framing off leaves it real.
    var overridesScreenBounds = true
    /// Stripes the Duo's reserved regions (camera occlusion, fold crease) as a keep-out guide, without changing the
    /// layout. Off by default.
    var showsReservedRegions = false

    private static let defaultsKey = "DuoFrameSimulator.settings"

    /// Reads the saved settings, or base64 JSON passed as a launch argument (`-DuoFrameSimulator.settings <b64>`)
    /// so a scheme or `simctl launch` can start straight into a preset. Base64 because NSUserDefaults parses a raw
    /// `{…}` argument as a plist and drops it.
    static func load() -> DuoFrameSettings {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: defaultsKey)
            ?? defaults.string(forKey: defaultsKey).flatMap { Data(base64Encoded: $0) }
        guard let data, let settings = try? JSONDecoder().decode(DuoFrameSettings.self, from: data) else {
            return DuoFrameSettings()
        }
        return settings
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    var geometry: DuoFrameGeometry? {
        switch preset {
        case .off:
            return nil
        case .otherDevice:
            // A plain framed phone: portrait size classes, its own safe area, uniform corners, no Duo side controls.
            let size = otherDevice.size
            return DuoFrameGeometry(
                preset: preset,
                size: size,
                horizontalSizeClass: size.width >= 600 ? .regular : .compact,
                verticalSizeClass: size.height >= 500 ? .regular : .compact,
                sideEdge: nil,
                safeAreaInsets: otherDevice.safeAreaInsets,
                isSplit: false,
                cornerRadii: DuoFrameCornerRadii(uniform: otherDevice.cornerRadius),
                zoom: displayZoom ? otherDevice.displayZoomFactor : 1,
                pointsPerInch: otherDevice.pointsPerInch
            )
        case .outerLandscape, .outerPortrait, .innerLandscape, .innerPortrait, .innerSplitHalf:
            guard let size = preset.size(custom: customSize) else { return nil }
            let sizeClasses = preset.sizeClasses(for: size)
            let usesSideControls = preset.usesSideControls(for: size)
            let edge = usesSideControls ? sideEdge.activeEdge : nil
            return DuoFrameGeometry(
                preset: preset,
                size: size,
                horizontalSizeClass: sizeClasses.horizontal,
                verticalSizeClass: sizeClasses.vertical,
                sideEdge: edge,
                safeAreaInsets: usesSideControls ? sideEdge.sideControlsInsets : DuoFrameInsets.portrait,
                isSplit: preset.isSplit,
                cornerRadii: DuoFrameCornerRadii.forPane(preset: preset, edge: edge, isCompanion: false),
                zoom: displayZoom ? DuoDevice.defaultDisplayZoomFactor : 1,
                pointsPerInch: DuoDevice.duoPointsPerInch
            )
        }
    }
}
#endif
