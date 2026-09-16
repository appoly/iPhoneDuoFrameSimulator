//
//  DuoFrameMenuButton.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

/// Floating control in the window's top-right corner, mirroring the iPad window controls on the left.
final class DuoFrameMenuButton: UIButton {

    private weak var controller: DuoFrameViewController?

    init(controller: DuoFrameViewController) {
        self.controller = controller
        super.init(frame: .zero)
        var configuration: UIButton.Configuration
        if #available(iOS 26, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "iphone.and.arrow.left.and.arrow.right")
            ?? UIImage(systemName: "rectangle.split.2x1")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 14, weight: .semibold)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9)
        self.configuration = configuration
        showsMenuAsPrimaryAction = true
        accessibilityLabel = "Duo frame simulator"
        menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuElements() ?? [])
            }
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DuoFrameMenuButton is created in code only")
    }

    private func menuElements() -> [UIMenuElement] {
        guard let controller else { return [] }
        let settings = controller.settings

        let duoPresets = UIMenu(
            options: .displayInline,
            children: DuoFramePreset.allCases.filter { $0 != .otherDevice }.map { preset in
                UIAction(
                    title: preset.title,
                    subtitle: preset.subtitle,
                    state: settings.preset == preset ? .on : .off
                ) { _ in
                    controller.settings.preset = preset
                }
            }
        )

        let otherSizes = otherSizesMenu(settings: settings, controller: controller)

        // Options that can't take effect are shown disabled and unticked, keeping their stored value for later.
        let isFramed = settings.geometry != nil
        let usesSideControls = settings.geometry.map { $0.preset.usesSideControls(for: $0.size) } ?? false
        let hasSideEdge = settings.geometry?.sideEdge != nil

        let sideEdges = UIMenu(
            title: "Side controls",
            subtitle: usesSideControls ? settings.sideEdge.title : "Not used by this pose",
            image: UIImage(systemName: "sidebar.right"),
            children: DuoFrameSideEdge.allCases.map { edge in
                UIAction(
                    title: edge.title,
                    attributes: usesSideControls ? [] : .disabled,
                    state: usesSideControls && settings.sideEdge == edge ? .on : .off
                ) { _ in
                    controller.settings.sideEdge = edge
                }
            }
        )

        let options = UIMenu(
            title: "Options",
            image: UIImage(systemName: "slider.horizontal.3"),
            children: [
                toggle("Override size classes", keyPath: \.overridesSizeClasses, enabled: isFramed),
                toggle(
                    "Report phone idiom",
                    subtitle: "UIKit honours it inconsistently",
                    keyPath: \.reportsPhoneIdiom,
                    enabled: isFramed
                ),
                toggle(
                    "Match physical size",
                    subtitle: "Scales so a point is the device's physical size",
                    keyPath: \.matchesPhysicalDensity,
                    enabled: isFramed
                ),
                toggle(
                    "Display Zoom",
                    subtitle: "Fewer layout points, zoomed UIScreen.nativeScale; rebuilds the SwiftUI tree",
                    keyPath: \.displayZoom,
                    enabled: isFramed
                ),
                toggle(
                    "Override UIScreen.bounds",
                    subtitle: "Reports the frame size; may misplace the keyboard",
                    keyPath: \.overridesScreenBounds,
                    enabled: isFramed
                ),
                toggle(
                    "Simulate vertical bars",
                    subtitle: hasSideEdge
                        ? "Hides the system bars; their items move to the side strip"
                        : "Needs a pose with side controls and an edge",
                    keyPath: \.simulatesVerticalBars,
                    enabled: hasSideEdge
                )
            ]
        )

        let status = UIAction(
            title: controller.statusSummary(),
            image: UIImage(systemName: "info.circle"),
            attributes: .disabled
        ) { _ in }

        return [duoPresets, otherSizes, sideEdges, options, UIMenu(options: .displayInline, children: [status])]
    }

    /// Non-Duo frames: released iPhone form factors plus a custom size. Side controls don't apply to these.
    private func otherSizesMenu(settings: DuoFrameSettings, controller: DuoFrameViewController) -> UIMenu {
        let isOther = settings.preset == .otherDevice
        let devices = DuoDevice.phones.map { device in
            UIAction(
                title: device.name,
                subtitle: "\(Int(device.size.width))×\(Int(device.size.height)) pt",
                state: isOther && settings.otherDevice == device ? .on : .off
            ) { _ in
                controller.settings.otherDevice = device
                controller.settings.preset = .otherDevice
            }
        }
        let custom = UIAction(
            title: "Custom size…",
            subtitle: settings.otherDevice.isCustom
                ? "\(Int(settings.otherDevice.size.width))×\(Int(settings.otherDevice.size.height)) pt"
                : nil,
            state: isOther && settings.otherDevice.isCustom ? .on : .off
        ) { _ in
            controller.promptForCustomSize()
        }
        return UIMenu(
            title: "Other sizes",
            subtitle: isOther ? settings.otherDevice.name : nil,
            image: UIImage(systemName: "iphone.gen3"),
            children: devices + [UIMenu(options: .displayInline, children: [custom])]
        )
    }

    private func toggle(
        _ title: String,
        subtitle: String? = nil,
        keyPath: WritableKeyPath<DuoFrameSettings, Bool>,
        enabled: Bool = true
    ) -> UIAction {
        let isOn = enabled && (controller?.settings[keyPath: keyPath] ?? false)
        return UIAction(
            title: title,
            subtitle: subtitle,
            attributes: enabled ? [] : .disabled,
            state: isOn ? .on : .off
        ) { [weak controller] _ in
            controller?.settings[keyPath: keyPath].toggle()
        }
    }
}

private extension DuoFramePreset {
    /// Only the Duo presets have a fixed size; Off and Other sizes return nil (Other sizes lists each device instead).
    var subtitle: String? {
        guard let size = size(custom: .zero) else { return nil }
        let classes = sizeClasses(for: size)
        return "\(Int(size.width))×\(Int(size.height)) pt · \(classes.horizontal.letter)×\(classes.vertical.letter)"
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
#endif
