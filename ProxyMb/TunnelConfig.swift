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
            .map { local, remote in "-L \(local):\(remote)" }
            .joined(separator: " ")
        return "ssh \(portMappings) \(sshHost)"
    }
}

// PortStatus lives in PortStatus.swift
