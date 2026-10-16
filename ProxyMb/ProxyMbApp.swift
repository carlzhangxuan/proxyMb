//
//  ProxyMbApp.swift
//  ProxyMb
//
//  Created by zx on 2025/10/21.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private let isSmokeTest = ProcessInfo.processInfo.arguments.contains("--smoke-test")
    lazy var tunnelManager: TunnelManager = {
        guard isSmokeTest else { return TunnelManager() }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--smoke-test"),
              arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else {
            fputs("--smoke-test requires an absolute temporary runtime directory\n", stderr)
            exit(64)
        }
        return TunnelManager(startRuntime: false,
                             homeDirectory: URL(fileURLWithPath: arguments[index + 1]),
                             environment: [:],
                             networkSetupExecutable: "/usr/bin/false",
                             lsofExecutable: "/usr/bin/false")
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if isSmokeTest {
            let view = NSHostingView(rootView: ContentView().environmentObject(tunnelManager))
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
            view.layoutSubtreeIfNeeded()
            print("ProxyMb startup check passed")
            NSApp.terminate(nil)
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isSmokeTest { return .terminateNow }
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
