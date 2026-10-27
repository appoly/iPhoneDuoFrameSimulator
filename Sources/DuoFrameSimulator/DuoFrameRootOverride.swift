//
//  DuoFrameRootOverride.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 26/10/2026.
//

#if DEBUG
import UIKit

/// SwiftUI pushes a changed `App.body` into a scene by reading the window's `rootViewController` as the hosting
/// controller it made, so once that's a `DuoFrameViewController` the update is dropped and App-level state never
/// reaches the views. This swizzles the getter so SwiftUI's reads get the hosted root; every other caller is unchanged.
enum DuoFrameRootOverride {

    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(getter: UIWindow.rootViewController)),
              let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.duoFrameRootViewController))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Frames 0–2 are this property, the swizzled getter and its `@objc` thunk, so the caller is within the first four.
    fileprivate static var isCalledFromSwiftUI: Bool {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 4)
        let count = Int(backtrace(&frames, Int32(frames.count)))
        return frames.prefix(count).contains { address in
            var info = Dl_info()
            guard let address, dladdr(address, &info) != 0, let path = info.dli_fname else { return false }
            let image = String(cString: path)
            return image.hasSuffix("/SwiftUI.framework/SwiftUI") || image.hasSuffix("/SwiftUICore.framework/SwiftUICore")
        }
    }
}

extension UIWindow {
    // After the exchange this body runs for the public getter, and calling it by name reaches the original.
    @objc func duoFrameRootViewController() -> UIViewController? {
        let root = duoFrameRootViewController()
        guard let frame = root as? DuoFrameViewController, DuoFrameRootOverride.isCalledFromSwiftUI else { return root }
        return frame.root
    }
}
#endif
