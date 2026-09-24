//
//  DuoFrameWindowInsets.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 24/09/2026.
//

#if DEBUG
import UIKit

/// A window reports the host's safe area along its own edges wherever it sits, so the framed window claimed the host's
/// Dynamic Island inset even when framed well clear of it, and UIKit drew its scroll edge effect across the top. This
/// swizzles the window's `safeAreaInsets` to report the simulated device's top and bottom insets instead. The sides
/// stay the window's own: a side inset would narrow sheets, which on the Duo run under the side-controls strip.
enum DuoFrameWindowInsets {
    /// The framed app window; only it is adjusted.
    static weak var framedWindow: UIWindow?
    /// Whose top and bottom are reported in place of the host's, or nil when framing is off.
    static var reported: UIEdgeInsets?

    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let getter = #selector(getter: UIView.safeAreaInsets)
        guard let inherited = class_getInstanceMethod(UIView.self, getter),
              let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.duoFrameSafeAreaInsets))
        else { return }
        class_addMethod(UIWindow.self, getter, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        guard let own = class_getInstanceMethod(UIWindow.self, getter) else { return }
        method_exchangeImplementations(own, replacement)
    }
}

extension UIWindow {
    @objc func duoFrameSafeAreaInsets() -> UIEdgeInsets {
        let own = duoFrameSafeAreaInsets()
        guard self === DuoFrameWindowInsets.framedWindow, let reported = DuoFrameWindowInsets.reported else {
            return own
        }
        return UIEdgeInsets(top: reported.top, left: own.left, bottom: reported.bottom, right: own.right)
    }
}
#endif
