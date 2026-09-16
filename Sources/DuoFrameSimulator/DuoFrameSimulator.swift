//
//  DuoFrameSimulator.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import SwiftUI

/// Debug-only harness for checking layouts at iPhone Duo display sizes before the 27.1 simulator ships.
/// Call `install()` once before the first window appears (e.g. in `App.init` or `didFinishLaunching`); every
/// app window's root is then re-parented under a `DuoFrameViewController`, driven from a menu in the top-right corner.
/// The menu button is hidden by default and toggled with a shake gesture; pass `showsButton: true` to start visible.
public enum DuoFrameSimulator {

    /// Posted after the faked `UIScreen` metrics (Display Zoom's `nativeScale`, the optional `bounds`) change. SwiftUI
    /// only re-runs a `body` whose inputs changed, so sizes computed from `UIScreen.main` inside `body` stay stale
    /// until the tree is rebuilt; see `duoFrameRebuildOnScreenMetricsChange()`.
    public static let screenMetricsDidChange = Notification.Name("DuoFrameSimulator.screenMetricsDidChange")

    private static var isInstalled = false
    private(set) static var showsButtonByDefault = false

    public static func install(showsButton: Bool = false) {
        guard !isInstalled else { return }
        isInstalled = true
        showsButtonByDefault = showsButton
        DuoFrameScreenOverride.install()
        DuoFramePresentationOverride.install()
        for name in [UIWindow.didBecomeVisibleNotification, UIWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let window = notification.object as? UIWindow else { return }
                DispatchQueue.main.async { wrap(window) }
            }
        }
    }

    /// UIKit's own windows (keyboard, text effects, alerts) have UIKitCore-owned roots and are left alone.
    private static func wrap(_ window: UIWindow) {
        guard window.windowLevel == .normal,
              window.windowScene?.session.role == .windowApplication,
              let root = window.rootViewController,
              !(root is DuoFrameViewController),
              Bundle(for: type(of: root)).bundleIdentifier != "com.apple.UIKitCore"
        else { return }
        window.rootViewController = DuoFrameViewController(hosting: root)
    }
}

public extension View {
    /// Optional second integration point, for the root content of a `WindowGroup`: gives the whole tree a new identity
    /// whenever the faked screen metrics change, the in-app equivalent of the relaunch iOS performs for a real Display
    /// Zoom change. Everything below it is recreated, so navigation and `@State` are lost, exactly as on a relaunch.
    func duoFrameRebuildOnScreenMetricsChange() -> some View {
        modifier(DuoFrameRebuildModifier())
    }
}

private struct DuoFrameRebuildModifier: ViewModifier {
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .id(generation)
            .onReceive(NotificationCenter.default.publisher(for: DuoFrameSimulator.screenMetricsDidChange)) { _ in
                generation += 1
            }
    }
}
#endif
