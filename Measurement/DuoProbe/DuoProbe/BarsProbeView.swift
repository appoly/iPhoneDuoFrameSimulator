import SwiftUI
import UIKit

// Real container-managed bars (six-tab TabView, navigation bar, toolbar placements, a sheet) so each pose can be
// compared against the frame simulator. Snapshots go to Documents/duo-bars.json; screenshots remain the ground
// truth for icon/text rendering, which the view tree can't express.

struct BarView: Codable, Equatable {
    var className: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isHidden: Bool
    var alpha: Double
    var itemCount: Int?
}

struct BarsSnapshot: Codable, Equatable {
    var signature: String
    var capturedAt: String
    var deviceIdiom: String
    var traitIdiom: String
    var selectedTab: String
    var tabBarMode: String?
    var isTabBarHidden: Bool?
    var sheetWidth: Double?
    var sheetHeight: Double?
    var bars: [BarView]
}

enum ProbeTab: String, CaseIterable, Identifiable {
    case home, library, inbox, favourites, profile, settings, search

    var id: Self { self }

    /// `-tabCount N` launches with only the first N tabs, to measure how the bar sizes to its item count.
    static var probed: [ProbeTab] {
        let count = UserDefaults.standard.integer(forKey: "tabCount")
        return count > 0 ? Array(allCases.prefix(count)) : allCases
    }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .inbox: "tray"
        case .favourites: "star"
        case .profile: "person.crop.circle"
        case .settings: "gear"
        case .search: "magnifyingglass"
        }
    }
}

struct BarsProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ProbeTab.home
    @State private var store: [String: BarsSnapshot] = [:]
    @State private var current: BarsSnapshot?
    @State private var isSheetPresented = false
    @State private var sheetSize: CGSize?

    var body: some View {
        TabView(selection: $selection) {
            ForEach(ProbeTab.probed) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab, role: tab == .search ? .search : nil) {
                    NavigationStack {
                        report(for: tab)
                            .navigationTitle(tab.title)
                            .toolbar { toolbarContent }
                    }
                }
            }
        }
        .sheet(isPresented: $isSheetPresented, onDismiss: { sheetSize = nil; scheduleCapture() }) {
            NavigationStack {
                GeometryReader { proxy in
                    List { Text("Sheet \(Int(proxy.size.width)) x \(Int(proxy.size.height)) pt") }
                        .onGeometryChange(for: CGSize.self) { _ in proxy.size } action: { size in
                            sheetSize = size
                            scheduleCapture()
                        }
                }
                .navigationTitle("Sheet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { isSheetPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", systemImage: "checkmark") { isSheetPresented = false }
                    }
                }
            }
        }
        .onChange(of: selection) { scheduleCapture() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close probe", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Compose", systemImage: "square.and.pencil") {}
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            Button("Share", systemImage: "square.and.arrow.up") {}
            Button("Duplicate", systemImage: "plus.square.on.square") {}
            Button("Archive", systemImage: "archivebox") {}
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Flag", systemImage: "flag") {}
            Button("Delete", systemImage: "trash") {}
        }
    }

    private func report(for tab: ProbeTab) -> some View {
        List {
            Section {
                Button("Present sheet") { isSheetPresented = true }
                NavigationLink("Push detail") {
                    Text("Detail").navigationTitle("Detail").onAppear(perform: scheduleCapture)
                }
                Text("Captured: \(store.count)")
            }
            if let current {
                Section("Current") {
                    Text(summary(current)).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in scheduleCapture() }
        .onAppear(perform: scheduleCapture)
    }

    // Bars settle a runloop or two after the content's geometry does.
    private func scheduleCapture() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            capture()
        }
    }

    private func capture() {
        guard let window = keyWindow() else { return }
        let tabController = findTabBarController(from: window.rootViewController)
        let traits = window.traitCollection
        let bars = findBars(in: window, window: window)
        let signature = "\(Int(window.bounds.width))x\(Int(window.bounds.height)) "
            + "\(letter(traits.horizontalSizeClass))x\(letter(traits.verticalSizeClass))"
            + (sheetSize == nil ? "" : " sheet")

        let snapshot = BarsSnapshot(
            signature: signature,
            capturedAt: ISO8601DateFormatter().string(from: .now),
            deviceIdiom: idiomName(UIDevice.current.userInterfaceIdiom),
            traitIdiom: idiomName(traits.userInterfaceIdiom),
            selectedTab: selection.rawValue,
            tabBarMode: tabController.map { modeName($0.mode) },
            isTabBarHidden: tabController?.isTabBarHidden,
            sheetWidth: sheetSize.map { Double($0.width) },
            sheetHeight: sheetSize.map { Double($0.height) },
            bars: bars
        )
        current = snapshot
        store[signature] = snapshot
        persist()
    }

    // Outermost views whose class name contains "Bar", so private floating/vertical bar classes are caught without
    // descending into their internals. Window-sized matches are the floating-bar containers, not bars.
    private func findBars(in view: UIView, window: UIWindow) -> [BarView] {
        let name = String(describing: type(of: view))
        let frame = view.convert(view.bounds, to: window)
        guard name.contains("Bar"), !name.contains("StatusBar"), !name.contains("ScrollIndicator"),
              frame.size != window.bounds.size else {
            return view.subviews.flatMap { findBars(in: $0, window: window) }
        }
        let itemCount: Int? = switch view {
        case let tabBar as UITabBar: tabBar.items?.count
        case let navBar as UINavigationBar: navBar.items?.count
        case let toolbar as UIToolbar: toolbar.items?.count
        default: nil
        }
        return [BarView(
            className: name,
            x: Double(frame.minX), y: Double(frame.minY),
            width: Double(frame.width), height: Double(frame.height),
            isHidden: view.isHidden || view.window == nil,
            alpha: Double(view.alpha),
            itemCount: itemCount
        )]
    }

    private func findTabBarController(from controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabController = controller as? UITabBarController { return tabController }
        for child in controller.children {
            if let found = findTabBarController(from: child) { return found }
        }
        return findTabBarController(from: controller.presentedViewController)
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }

    private func persist() {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("duo-bars.json") else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: url)
    }

    private func summary(_ snapshot: BarsSnapshot) -> String {
        let sheet = snapshot.sheetWidth.map { "sheet     \(Int($0)) x \(Int(snapshot.sheetHeight ?? 0))\n" } ?? ""
        let bars = snapshot.bars.map {
            "\($0.className)\($0.isHidden ? " (hidden)" : "") \(Int($0.width))x\(Int($0.height)) "
                + "@\(Int($0.x)),\(Int($0.y))\($0.itemCount.map { " items=\($0)" } ?? "")"
        }
        return """
        \(snapshot.signature)
        idiom     device \(snapshot.deviceIdiom)  trait \(snapshot.traitIdiom)
        tabs      mode \(snapshot.tabBarMode ?? "n/a")  hidden \(snapshot.isTabBarHidden.map(String.init) ?? "n/a")
        \(sheet)\(bars.joined(separator: "\n"))
        """
    }

    private func letter(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "C"
        case .regular: "R"
        case .unspecified: "?"
        @unknown default: "?"
        }
    }

    private func idiomName(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: "phone"
        case .pad: "pad"
        case .mac: "mac"
        case .tv: "tv"
        case .carPlay: "carPlay"
        case .vision: "vision"
        case .unspecified: "unspecified"
        @unknown default: "unknown(\(idiom.rawValue))"
        }
    }

    private func modeName(_ mode: UITabBarController.Mode) -> String {
        switch mode {
        case .automatic: "automatic"
        case .tabBar: "tabBar"
        case .tabSidebar: "tabSidebar"
        @unknown default: "unknown(\(mode.rawValue))"
        }
    }
}
