//
//  ProxyMbApp.swift
//  ProxyMb
//
//  Created by zx on 2025/10/21.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var tunnelManager: TunnelManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let tm = tunnelManager {
            tm.refreshAll()
        }
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort: trigger a refresh again in case termination path differs
        tunnelManager?.refreshAll()
    }
    
    private func cleanupSystemProxyFallback() {
        // Fallback remains (unused with simplified flow)
        let tool = "/usr/sbin/networksetup"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let services = getNetworkServices()
        for service in services { _ = runCommand(tool, ["-setsocksfirewallproxystate", service, "off"]) }
    }
    
    private func getNetworkServices() -> [String] {
        let tool = "/usr/sbin/networksetup"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return [] }
        let (output, code) = runCommand(tool, ["-listallnetworkservices"])
        guard code == 0 else { return [] }
        var result: [String] = []
        for (index, line) in output.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 && trimmed.lowercased().contains("asterisk") { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("*") { continue }
            result.append(trimmed)
        }
        return result
    }
    
    private func runCommand(_ path: String, _ args: [String]) -> (String, Int32) {
        let process = Process()
        process.launchPath = path
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run(); process.waitUntilExit() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
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
