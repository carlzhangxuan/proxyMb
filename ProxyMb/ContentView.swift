import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @State private var showLogs: Bool = false

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
                        Button("Load Config") { openAndLoadConfig() }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        Button("Refresh") { tunnelManager.refreshStatusFromSystem() }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
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

                // Logs panel (collapsible, minimal impact on layout)
                DisclosureGroup(isExpanded: $showLogs) {
                    logToolbar
                    logList
                } label: {
                    HStack(spacing: 6) {
                        // Image(systemName: "ladybug.fill").foregroundStyle(.secondary)
                        Text("Logs").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(tunnelManager.logEntries.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .tint(.secondary)
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .padding(16)
        }
        .frame(maxHeight: maxContentHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var contentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SocksCard() // fixed SOCKS proxy control
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(tunnelManager.tunnels) { tunnel in
                TunnelCard(tunnel: tunnel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Logs UI

    private var logToolbar: some View {
        HStack(spacing: 8) {
            Button { tunnelManager.clearLogs() } label: {
                Label("Clear", systemImage: "trash")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button {
                let url = tunnelManager.logFileURLForUI
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? "".data(using: .utf8)?.write(to: url)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Open Logs", systemImage: "folder")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(tunnelManager.logEntries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timeString(entry.timestamp))
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(levelTag(entry.level))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(levelColor(entry.level).opacity(0.12))
                            .foregroundStyle(levelColor(entry.level))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(entry.message)
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 160)
    }

    private func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }
    private func levelTag(_ level: TunnelManager.LogLevel) -> String {
        switch level {
        case .info: return "INFO"
        case .error: return "ERROR"
        case .stdout: return "OUT"
        case .stderr: return "ERR"
        }
    }
    private func levelColor(_ level: TunnelManager.LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .error: return .red
        case .stdout: return .green
        case .stderr: return .orange
        }
    }

    // MARK: - Config loader UI
    private func openAndLoadConfig() {
        let panel = NSOpenPanel()
        panel.title = "Choose a config JSON"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, let url = panel.url {
            tunnelManager.loadConfig(from: url)
        }
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

struct SocksCard: View {
    @EnvironmentObject var tunnelManager: TunnelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(tunnelManager.isSocksActive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("SOCKS Proxy (0.0.0.0:1080)")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if tunnelManager.isSocksActive {
                    Button("Stop") { tunnelManager.stopSocks() }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                } else {
                    Button("Start") { tunnelManager.startSocks() }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }

            Divider().opacity(0.12)
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text("via host: tunnel • ssh -ND 0.0.0.0:1080")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .padding(.trailing, 2)
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
