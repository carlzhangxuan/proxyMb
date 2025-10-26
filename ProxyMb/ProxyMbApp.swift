//
//  ProxyMbApp.swift
//  ProxyMb
//
//  Created by zx on 2025/10/21.
//

import SwiftUI

@main
struct ProxyMbApp: App {
    @StateObject private var tunnelManager = TunnelManager()

    var body: some Scene {
        MenuBarExtra("SSH", systemImage: "terminal.fill") {
            ContentView()
                .environmentObject(tunnelManager)
                .frame(minWidth: 500)
        }
        .menuBarExtraStyle(.window)
    }
}
