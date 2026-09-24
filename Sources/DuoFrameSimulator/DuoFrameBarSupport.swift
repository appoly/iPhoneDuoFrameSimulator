//
//  DuoFrameBarSupport.swift
//  DuoFrameSimulator
//

#if DEBUG
import UIKit

extension UIViewController {
    /// The deepest full-screen presentation above this controller, or itself when nothing full-screen is presented.
    /// Sheets and popovers stop the walk: they're shaped surfaces that keep their own bars.
    var duoFrameFrontmostFullScreen: UIViewController {
        var top = self
        while let presented = top.presentedViewController,
              !presented.isBeingDismissed,
              presented.duoFrameIsFullScreenPresentation {
            top = presented
        }
        return top
    }

    /// A sheet or popover over the frontmost full-screen presentation, if one is showing.
    var duoFrameFrontmostSheet: UIViewController? {
        var sheet: UIViewController?
        var top = duoFrameFrontmostFullScreen
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            if !presented.duoFrameIsFullScreenPresentation { sheet = presented }
            top = presented
        }
        return sheet
    }

    /// Container controllers whose views are on screen, in hierarchy order, so the last navigation controller is the
    /// one driving the visible screen.
    var duoFrameOnScreenContainers: [UIViewController] {
        guard isViewLoaded, view.window != nil else { return [] }
        let own: [UIViewController] = self is UITabBarController || self is UINavigationController ? [self] : []
        return own + children.flatMap(\.duoFrameOnScreenContainers)
    }
}

extension UITabBarController {
    var duoFrameIsTabBarHidden: Bool {
        get {
            if #available(iOS 18, *) { return isTabBarHidden }
            return tabBar.isHidden
        }
        set {
            if #available(iOS 18, *) {
                isTabBarHidden = newValue
            } else {
                tabBar.isHidden = newValue
            }
        }
    }

    func duoFrameSelectTab(at index: Int) {
        if #available(iOS 18, *), tabs.indices.contains(index) {
            selectedTab = tabs[index]
        } else if let controllers = viewControllers, controllers.indices.contains(index) {
            selectedIndex = index
        }
        if let items = tabBar.items, items.indices.contains(index) {
            tabBar.delegate?.tabBar?(tabBar, didSelect: items[index])
        }
    }
}

extension UIImage {
    func duoFrameFitted(to side: CGFloat) -> UIImage {
        let scale = min(side / max(size.width, 1), side / max(size.height, 1), 1)
        guard scale < 1 else { return self }
        let fittedSize = CGSize(width: size.width * scale, height: size.height * scale)
        let scaled = UIGraphicsImageRenderer(size: fittedSize).image { _ in
            draw(in: CGRect(origin: .zero, size: fittedSize))
        }
        return scaled.withRenderingMode(renderingMode)
    }
}

extension UIVisualEffectView {
    /// Liquid Glass capsule on iOS 26+, a chrome-material blur rounded to `fallbackRadius` before it.
    static func duoFrameGlass(fallbackRadius: CGFloat) -> UIVisualEffectView {
        let glass: UIVisualEffectView
        if #available(iOS 26, *) {
            glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .capsule()
        } else {
            glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            glass.clipsToBounds = true
            glass.layer.cornerRadius = fallbackRadius
        }
        glass.translatesAutoresizingMaskIntoConstraints = false
        return glass
    }
}
#endif
