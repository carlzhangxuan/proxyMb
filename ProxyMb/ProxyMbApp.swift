//
//  ProxyMbApp.swift
//  ProxyMb
//
//  Created by zx on 2025/10/21.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct ProxyMbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var tunnelManager = TunnelManager()

    var body: some Scene {
        MenuBarExtra("ProxyMb", systemImage: "network") {
            ContentView()
                .environmentObject(tunnelManager)
                .frame(width: 560)
        }
        .menuBarExtraStyle(.window)
    }
}
