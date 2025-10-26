import SwiftUI

enum PortStatus: Equatable {
    case unknown
    case checking
    case listening
    case notListening

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
