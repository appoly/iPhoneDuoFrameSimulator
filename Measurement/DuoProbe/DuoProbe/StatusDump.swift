import UIKit

// `-dumpStatus YES` writes Documents/status-dump.txt: every status-bar, backdrop and effect view in the process, with
// its layer tree's filters, so the system status pill's material can be read off the real Duo simulator.
enum StatusDump {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "dumpStatus") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { write() }
    }

    private static let keys = ["name", "type", "inputRadius", "inputAmount", "inputColorMatrix", "inputBias",
                               "inputNormalizeEdges", "inputHardEdges", "inputQuality", "inputMaskImage",
                               "inputSaturation", "inputBrightness", "inputColor"]

    private static func write() {
        var lines: [String] = []
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            lines.append("WINDOW \(type(of: window)) level=\(window.windowLevel.rawValue) frame=\(window.frame)")
            walk(window, in: window, depth: 1, into: &lines)
        }
        let text = lines.joined(separator: "\n")
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("status-dump.txt") {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        print("STATUSDUMP lines=\(lines.count)")
    }

    private static func walk(_ view: UIView, in window: UIWindow, depth: Int, into lines: inout [String]) {
        let name = String(describing: type(of: view))
        let interesting = ["Status", "Backdrop", "VisualEffect", "Material", "Glass", "Platter", "Blur"]
            .contains { name.contains($0) }
        if interesting {
            let frame = view.convert(view.bounds, to: window)
            let indent = String(repeating: "  ", count: depth)
            var line = "\(indent)\(name) frame=\(frame) alpha=\(view.alpha) hidden=\(view.isHidden)"
            if let effect = (view as? UIVisualEffectView)?.effect { line += " effect=\(effect)" }
            lines.append(line)
            dumpLayer(view.layer, depth: depth + 1, into: &lines)
        }
        for subview in view.subviews {
            walk(subview, in: window, depth: interesting ? depth + 1 : depth, into: &lines)
        }
    }

    private static func dumpLayer(_ layer: CALayer, depth: Int, into lines: inout [String]) {
        guard depth < 14 else { return }
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)layer \(type(of: layer)) bounds=\(layer.bounds.size) opacity=\(layer.opacity)"
        if let colour = layer.backgroundColor { line += " bg=\(UIColor(cgColor: colour))" }
        if let filter = layer.compositingFilter { line += " compositing=\(filter)" }
        lines.append(line)
        for filter in (layer.filters ?? []) + (layer.backgroundFilters ?? []) {
            let object = filter as AnyObject
            let values = keys.compactMap { key -> String? in
                guard object.responds(to: NSSelectorFromString(key)) || key.hasPrefix("input") else { return nil }
                guard let value = (object as? NSObject)?.value(forKey: key) else { return nil }
                return "\(key)=\(value)"
            }
            lines.append("\(indent)  filter \(values.joined(separator: " "))")
        }
        for sublayer in layer.sublayers ?? [] {
            dumpLayer(sublayer, depth: depth + 1, into: &lines)
        }
    }
}
