//
//  DuoProbeApp.swift
//  DuoProbe
//
//  Created by Simon Frost on 22/09/2026.
//

import SwiftUI

@main
struct DuoProbeApp: App {
    init() {
        StatusDump.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
