//
//  DuoFrameScreenOverride.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 16/09/2026.
//

#if DEBUG
import UIKit

/// Swizzles the `UIScreen` getters an app reads to detect Display Zoom or measure the screen, so code sizing itself
/// from `UIScreen.main` sees the simulated device rather than the host. A nil value leaves that getter untouched.
enum DuoFrameScreenOverride {

    /// Display Zoom factor (`scale / nativeScale`, below 1 when zoomed). `nativeScale` then reports `scale / zoom`.
    static var zoom: CGFloat?
    /// Reported from `bounds` in place of the host screen's size.
    static var bounds: CGSize?

    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        swizzle(#selector(getter: UIScreen.nativeScale), with: #selector(UIScreen.duoFrameNativeScale))
        swizzle(#selector(getter: UIScreen.bounds), with: #selector(UIScreen.duoFrameBounds))
    }

    /// The host's real value, bypassing the override.
    static func hostNativeScale(of screen: UIScreen) -> CGFloat {
        isInstalled ? screen.duoFrameNativeScale() : screen.nativeScale
    }

    private static func swizzle(_ original: Selector, with replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(UIScreen.self, original),
              let replacementMethod = class_getInstanceMethod(UIScreen.self, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

private extension UIScreen {
    // After the exchange these bodies run for the public getters, and calling them by name reaches the originals.
    @objc func duoFrameNativeScale() -> CGFloat {
        guard let zoom = DuoFrameScreenOverride.zoom else { return duoFrameNativeScale() }
        return scale / zoom
    }

    @objc func duoFrameBounds() -> CGRect {
        guard let size = DuoFrameScreenOverride.bounds else { return duoFrameBounds() }
        return CGRect(origin: .zero, size: size)
    }
}
#endif
