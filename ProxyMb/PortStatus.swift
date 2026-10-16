import SwiftUI

enum PortStatus: Equatable {
    case unknown
    case checking
    case listening
    case notListening

    var description: String {
        switch self {
        case .unknown: return "Local SSH listener status is unavailable or has not been checked"
        case .checking: return "Waiting for local SSH listeners, or stopping"
        case .listening: return "Local SSH listener detected; remote service health is not checked"
        case .notListening: return "No local SSH listener detected"
        }
    }

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .checking: return .orange
        case .listening: return .green
        case .notListening: return .red
        }
    }

    // SF Symbol name for UI usage
    var symbol: String {
        switch self {
        case .unknown: return "circle"
        case .checking: return "circle.dotted"
        case .listening: return "circle.fill"
        case .notListening: return "circle"
        }
    }
}

extension TunnelManager.SpaasState {
    var color: Color {
        switch self {
        case .idle: return .gray
        case .running: return .orange
        case .success: return .green
        case .failure: return .red
        }
    }

    var description: String {
        switch self {
        case .idle: return "No command result for this selection"
        case .running: return "Command is running"
        case .success: return "Last command succeeded; current credentials and remote service health are not checked"
        case .failure: return "Last command failed"
        }
    }
}
