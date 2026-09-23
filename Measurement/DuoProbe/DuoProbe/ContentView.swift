import SwiftUI
import UIKit

// Throwaway measurement harness. Run on the iPhone Duo simulator, then cycle every pose in Device Hub
// (open, closed, both rotations, partially folded, both Split View halves). Each distinct pose is captured
// into a dictionary keyed by size + size classes and written to Documents/duo-metrics.json, which the host
// pulls with `xcrun simctl get_app_container`. Nothing here ships in the package.

struct RegionInfo: Codable, Equatable {
    var kind: String
    var isActive: Bool
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var marginTop: Double
    var marginLeading: Double
    var marginBottom: Double
    var marginTrailing: Double
}

struct PoseMetrics: Codable, Equatable {
    var signature: String
    var capturedAt: String
    var screenWidth: Double
    var screenHeight: Double
    var width: Double
    var height: Double
    var safeTop: Double
    var safeLeading: Double
    var safeBottom: Double
    var safeTrailing: Double
    var horizontalSizeClass: String
    var verticalSizeClass: String
    var scale: Double
    var nativeScale: Double
    var displayCornerRadius: Double?
    var toolbarVerticalEdge: String
    var supportsMultipleWindows: Bool
    var hingeStatus: String
    var hingeAngleRadians: Double?
    var regions: [RegionInfo]
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var hClass
    @Environment(\.verticalSizeClass) private var vClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    @State private var store: [String: PoseMetrics] = [:]
    @State private var current: PoseMetrics?
    @State private var hingeStatus = "unknown"
    @State private var hingeAngle: Double?
    @State private var isBarsProbePresented = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Duo probe").font(.title2.bold())
                    Text("Poses captured: \(store.count)").font(.headline)
                    Text("Cycle every pose in Device Hub. Each writes to Documents/duo-metrics.json.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Bars probe") { isBarsProbePresented = true }
                        .buttonStyle(.borderedProminent)
                    Divider()
                    if let current {
                        Text(summary(current)).font(.system(.footnote, design: .monospaced))
                    }
                    Divider()
                    Text("All captured signatures:").font(.subheadline.bold())
                    ForEach(store.keys.sorted(), id: \.self) { key in
                        Text(key).font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onGeometryChange(for: String.self) { _ in
                let insets = proxy.safeAreaInsets
                return "\(proxy.size.width)x\(proxy.size.height)|"
                    + "\(insets.top),\(insets.leading),\(insets.bottom),\(insets.trailing)"
            } action: { _ in
                capture(proxy)
            }
            .onAppear { capture(proxy) }
            .onHingeChange { _, newValue in
                if let hinge = newValue.hinge {
                    hingeStatus = "\(hinge.status)"
                    hingeAngle = hinge.angle.radians
                } else {
                    hingeStatus = "none"
                    hingeAngle = nil
                }
                capture(proxy)
            }
        }
        .ignoresSafeArea(.container, edges: [])
        .fullScreenCover(isPresented: $isBarsProbePresented) { BarsProbeView() }
    }

    private func capture(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        let hLetter = letter(hClass)
        let vLetter = letter(vClass)
        let screen = activeScreen()
        let nativeScale = screen?.nativeScale ?? displayScale
        let fullWidth = screen.map { Double($0.bounds.width) } ?? Double(proxy.size.width + insets.leading + insets.trailing)
        let fullHeight = screen.map { Double($0.bounds.height) } ?? Double(proxy.size.height + insets.top + insets.bottom)
        let signature = "\(Int(fullWidth))x\(Int(fullHeight)) "
            + "\(hLetter)x\(vLetter) \(edgeName(verticalEdge)) \(hingeStatus) "
            + "@\(String(format: "%.3f", nativeScale))"

        let metrics = PoseMetrics(
            signature: signature,
            capturedAt: ISO8601DateFormatter().string(from: .now),
            screenWidth: fullWidth,
            screenHeight: fullHeight,
            width: Double(proxy.size.width),
            height: Double(proxy.size.height),
            safeTop: Double(insets.top),
            safeLeading: Double(insets.leading),
            safeBottom: Double(insets.bottom),
            safeTrailing: Double(insets.trailing),
            horizontalSizeClass: hLetter,
            verticalSizeClass: vLetter,
            scale: Double(screen?.scale ?? displayScale),
            nativeScale: Double(nativeScale),
            displayCornerRadius: cornerRadius(of: screen),
            toolbarVerticalEdge: edgeName(verticalEdge),
            supportsMultipleWindows: supportsMultipleWindows,
            hingeStatus: hingeStatus,
            hingeAngleRadians: hingeAngle,
            regions: regions(from: proxy)
        )
        current = metrics
        store[signature] = metrics
        persist()
    }

    private func regions(from proxy: GeometryProxy) -> [RegionInfo] {
        let division = proxy.reservedRegions(kind: .division, options: .includeInactive)
        let occlusion = proxy.reservedRegions(kind: .occlusion, options: .includeInactive)
        return division.map { info($0, "division") } + occlusion.map { info($0, "occlusion") }
    }

    private func info(_ region: ReservedRegion, _ name: String) -> RegionInfo {
        RegionInfo(
            kind: name,
            isActive: region.isActive,
            x: Double(region.frame.minX), y: Double(region.frame.minY),
            width: Double(region.frame.width), height: Double(region.frame.height),
            marginTop: Double(region.margins.top), marginLeading: Double(region.margins.leading),
            marginBottom: Double(region.margins.bottom), marginTrailing: Double(region.margins.trailing)
        )
    }

    private func persist() {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("duo-metrics.json") else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: url)
        if let json = String(data: data, encoding: .utf8) {
            print("DUOPROBE_JSON_BEGIN\n\(json)\nDUOPROBE_JSON_END path=\(url.path)")
        }
    }

    private func summary(_ m: PoseMetrics) -> String {
        """
        full      \(Int(m.screenWidth)) x \(Int(m.screenHeight)) pt  (\(m.horizontalSizeClass)x\(m.verticalSizeClass))
        content   \(Int(m.width)) x \(Int(m.height)) pt
        safe      t\(fmt(m.safeTop)) l\(fmt(m.safeLeading)) b\(fmt(m.safeBottom)) r\(fmt(m.safeTrailing))
        scale     \(fmt(m.scale))  native \(fmt(m.nativeScale))
        corner    \(m.displayCornerRadius.map(fmt) ?? "n/a")
        barEdge   \(m.toolbarVerticalEdge)   multiWindow \(m.supportsMultipleWindows)
        hinge     \(m.hingeStatus)  angle \(m.hingeAngleRadians.map { fmt($0) } ?? "n/a")
        regions   \(m.regions.isEmpty ? "none" : "")
        \(m.regions.map { "  \($0.kind) active=\($0.isActive) \(Int($0.width))x\(Int($0.height)) @\(Int($0.x)),\(Int($0.y))" }.joined(separator: "\n"))
        """
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    private func letter(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: "C"
        case .regular: "R"
        case .none: "?"
        @unknown default: "?"
        }
    }

    private func edgeName(_ edge: HorizontalEdge?) -> String {
        switch edge {
        case .leading: "leading"
        case .trailing: "trailing"
        case .none: "unspecified"
        }
    }

    private func activeScreen() -> UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }

    private func cornerRadius(of screen: UIScreen?) -> Double? {
        guard let screen else { return nil }
        let selector = NSSelectorFromString("_displayCornerRadius")
        guard screen.responds(to: selector),
              let value = screen.value(forKey: "_displayCornerRadius") as? Double else { return nil }
        return value
    }
}

#Preview {
    ContentView()
}
