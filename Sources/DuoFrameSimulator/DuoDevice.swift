//
//  DuoDevice.swift
//  DuoFrameSimulator
//
//  Created by Simon Frost on 15/09/2026.
//

#if DEBUG
import UIKit

/// A non-Duo frame the tool can render: a released iPhone form factor, or a one-off custom size. Point sizes are
/// portrait; the corner radius and safe-area insets are community-measured placeholders, not Apple-published values.
struct DuoDevice: Codable, Equatable {
    var name: String
    var size: CGSize
    var cornerRadius: CGFloat
    var safeTop: CGFloat
    var safeBottom: CGFloat

    var safeAreaInsets: UIEdgeInsets {
        UIEdgeInsets(top: safeTop, left: 0, bottom: safeBottom, right: 0)
    }

    /// Released iPhone form factors, smallest to largest. All fit an iPad-mini host at ≤1×; the larger ones letterbox
    /// down a little rather than needing a bigger screen than the host.
    static let phones: [DuoDevice] = [
        DuoDevice(name: "iPhone SE", portrait: 375, 667, corner: 0, top: 20, bottom: 0),
        DuoDevice(name: "iPhone mini", portrait: 375, 812, corner: 44, top: 50, bottom: 34),
        DuoDevice(name: "iPhone", portrait: 393, 852, corner: 55, top: 59, bottom: 34),
        DuoDevice(name: "iPhone XR", portrait: 414, 896, corner: 41, top: 44, bottom: 34),
        DuoDevice(name: "iPhone Plus", portrait: 430, 932, corner: 55, top: 59, bottom: 34),
        DuoDevice(name: "iPhone Pro", portrait: 402, 874, corner: 62, top: 59, bottom: 34),
        DuoDevice(name: "iPhone Pro Max", portrait: 440, 956, corner: 62, top: 59, bottom: 34)
    ]

    static let defaultOther = phones[0]

    static func custom(_ size: CGSize) -> DuoDevice {
        DuoDevice(name: "Custom", size: size, cornerRadius: 44, safeTop: 47, safeBottom: 34)
    }

    var isCustom: Bool { name == "Custom" }

    /// Portrait width each device lays out at with Display Zoom on. Keyed by name rather than stored, so persisted
    /// settings from before this table decode unchanged. Only the 6.3" Pro (iOS 26) is measured; the rest are
    /// community-reported.
    private static let zoomedWidths: [String: CGFloat] = [
        "iPhone SE": 320,
        "iPhone mini": 320,
        "iPhone": 320,
        "iPhone XR": 375,
        "iPhone Plus": 375,
        "iPhone Pro": 320,
        "iPhone Pro Max": 375
    ]

    /// Measured on an iPhone 17 Pro: 402 pt → 320 pt, `scale / nativeScale` = 3 / 3.76875. Used where the real
    /// value is unknown (custom sizes, the Duo).
    static let defaultDisplayZoomFactor: CGFloat = 320 / 402

    /// `UIScreen.scale / nativeScale` with Display Zoom on: the layout shrinks to `size × factor` points.
    var displayZoomFactor: CGFloat {
        guard let zoomedWidth = Self.zoomedWidths[name] else { return Self.defaultDisplayZoomFactor }
        return zoomedWidth / size.width
    }

    /// Points per inch (ppi ÷ scale), keyed by name for the same reason as `zoomedWidths`. 2x 326-ppi phones sit at
    /// 163, the 476-ppi mini at 159, every 460-ppi 3x phone at 153.
    private static let pointsPerInchByName: [String: CGFloat] = [
        "iPhone SE": 163,
        "iPhone mini": 159,
        "iPhone": 153,
        "iPhone XR": 163,
        "iPhone Plus": 153,
        "iPhone Pro": 153,
        "iPhone Pro Max": 153
    ]

    /// The Duo's assumed 460 ppi at 3x; also the fallback for custom sizes.
    static let duoPointsPerInch: CGFloat = 153

    var pointsPerInch: CGFloat {
        Self.pointsPerInchByName[name] ?? Self.duoPointsPerInch
    }
}

extension DuoDevice {
    /// Compact initialiser for the device table. Kept in an extension so the memberwise initialiser stays available.
    init(name: String, portrait width: CGFloat, _ height: CGFloat, corner: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.init(
            name: name, size: CGSize(width: width, height: height),
            cornerRadius: corner, safeTop: top, safeBottom: bottom
        )
    }
}
#endif
