import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var tunnelManager: TunnelManager

    // Layout caps to avoid oversized windows while keeping height dynamic
    private let maxContentWidth: CGFloat = 560
    private let maxContentHeight: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                // Header (constrained width)
                HStack(spacing: 12) {
                    Text("SSH Tunnels")
                        .font(.title3.bold())
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Stop All") { tunnelManager.stopAllTunnels() }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        Button("Quit") { NSApp.terminate(nil) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
                Divider().opacity(0.25)

                // Dynamic-height content: prefer no scroll, fall back to scroll if needed
                ViewThatFits(in: .vertical) {
                    contentList
                    ScrollView { contentList }
                }
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: maxContentHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var contentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(tunnelManager.tunnels) { tunnel in
                TunnelCard(tunnel: tunnel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TunnelCard: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    let tunnel: TunnelConfig

    private func portString(_ p: Int) -> String { String(p) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row header
            HStack(spacing: 10) {
                Circle()
                    .fill(tunnel.isActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(tunnel.name)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if tunnel.isActive {
                    Button("Stop") { tunnelManager.stopTunnel(for: tunnel.id) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                } else {
                    Button("Start") { tunnelManager.startTunnel(for: tunnel.id) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }

            Divider().opacity(0.12)

            // Port mappings
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(zip(tunnel.localPorts.indices, zip(tunnel.localPorts, tunnel.remoteTargets))), id: \.0) { _, pair in
                    let (lp, target) = pair
                    HStack(spacing: 8) {
                        let status: PortStatus = .unknown
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.color)
                        Text("localhost:\(portString(lp)) → \(target) via \(tunnel.sshHost)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .padding(.trailing, 2) // avoid trailing button clipping by window chrome
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(TunnelManager())
}
