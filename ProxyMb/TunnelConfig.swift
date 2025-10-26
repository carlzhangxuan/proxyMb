//
//  TunnelConfig.swift
//  ProxyMb
//
//  Created by zx on 2025/10/25.
//

import Foundation
import SwiftUI

struct TunnelConfig: Identifiable {
    let id = UUID()
    let name: String
    let localPorts: [Int]
    let remoteTargets: [String] // "host:port" format
    let sshHost: String
    var isActive: Bool = false
    
    // Generate complete SSH command
    var sshCommand: String {
        let portMappings = zip(localPorts, remoteTargets)
            .map { "-L \($0):\($1)" }
            .joined(separator: " ")
        return "ssh \(portMappings) \(sshHost)"
    }
    
    static let presets: [TunnelConfig] = [
        TunnelConfig(
            name: "🧪 Local Test Tunnel",
            localPorts: [9280, 40443, 40453],
            remoteTargets: [
                "localhost:8001",
                "localhost:8002",
                "localhost:8003"
            ],
            sshHost: "localhost"
        )
    ]
}

// PortStatus lives in PortStatus.swift
