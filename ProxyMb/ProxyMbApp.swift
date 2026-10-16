//
//  ProxyMbApp.swift
//  ProxyMb
//
//  Created by zx on 2025/10/21.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    let tunnelManager = TunnelManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        tunnelManager.cleanupSystemProxyOnExit {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ProxyMbApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("ProxyMb", systemImage: "network") {
            ContentView()
                .environmentObject(appDelegate.tunnelManager)
                .frame(width: 560)
        }
        .menuBarExtraStyle(.window)
    }
}
