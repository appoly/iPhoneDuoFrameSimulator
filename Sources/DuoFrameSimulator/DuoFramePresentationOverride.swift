//
//  DuoFramePresentationOverride.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 16/09/2026.
//

#if DEBUG
import UIKit

/// A full-screen presentation (`.fullScreenCover`, a full-screen modal) attaches to the window, above the hosted root,
/// so it never inherits the faked Duo safe area the shield hands the root — it lays out edge to edge, ignoring the
/// side-controls strip. This swizzles `present` so a full-screen presentation inside the framed window is given the
/// same faked insets through its own `additionalSafeAreaInsets`. Sheets and popovers are left alone; their card shape
/// shouldn't take a safe-area inset.
enum DuoFramePresentationOverride {

    /// The framed app window, or nil when framing is off. A presentation is only adjusted when it belongs to it.
    static weak var framedWindow: UIWindow?
    /// Added to a full-screen presentation so its safe area matches the faked one: the faked total minus what the
    /// window already reports, per edge. Sides are the interesting part (the window reports none, the Duo strip is
    /// entirely faked); top and bottom can't drop below what the window reports, since a presentation isn't shielded.
    static var additionalInsets: UIEdgeInsets = .zero

    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        swizzle(
            #selector(UIViewController.present(_:animated:completion:)),
            with: #selector(UIViewController.duoFramePresent(_:animated:completion:))
        )
    }

    private static func swizzle(_ original: Selector, with replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, original),
              let replacementMethod = class_getInstanceMethod(UIViewController.self, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

private extension UIViewController {
    @objc func duoFramePresent(_ viewControllerToPresent: UIViewController, animated: Bool, completion: (() -> Void)?) {
        duoFramePresent(viewControllerToPresent, animated: animated, completion: completion)   // the original
        guard let window = DuoFramePresentationOverride.framedWindow,
              view.window === window,
              viewControllerToPresent.duoFrameIsFullScreenPresentation else { return }
        let insets = DuoFramePresentationOverride.additionalInsets
        if viewControllerToPresent.additionalSafeAreaInsets != insets {
            viewControllerToPresent.additionalSafeAreaInsets = insets
        }
    }
}

extension UIViewController {
    /// True for a full-screen presentation style, false for a sheet or popover. A full-screen cover replaces the whole
    /// display, so on a Duo its bars move to the side strip and it takes the faked insets; a sheet is a shaped surface
    /// that keeps its own bars and shape.
    var duoFrameIsFullScreenPresentation: Bool {
        switch modalPresentationStyle {
        case .fullScreen, .overFullScreen, .currentContext, .overCurrentContext: true
        default: false
        }
    }
}
#endif
