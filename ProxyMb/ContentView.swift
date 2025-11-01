import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @State private var showLogs: Bool = false

    // Layout caps to avoid oversized windows while keeping height dynamic
    private let maxContentWidth: CGFloat = 560

    // Local selection state for grouped shortcuts
    @State private var selectedAwsSystem: String = ""
    @State private var selectedAwsEnv: String = ""
    @State private var selectedK8sSystem: String = ""
    @State private var selectedK8sEnv: String = ""

    // Importers
    @State private var showConfigImporter: Bool = false

    // Guard to avoid opening multiple panels at once
    @State private var isPresentingConfigPanel: Bool = false

    // Extracted sections to reduce type-checker load in Release builds
    @ViewBuilder private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Tunnels")
                .font(.title3.bold())
            Spacer()
            HStack(spacing: 8) {
                Button("Refresh") {
                    // Reset local UI selections so they repopulate after reload
                    selectedAwsSystem = ""; selectedAwsEnv = ""
                    selectedK8sSystem = ""; selectedK8sEnv = ""
                    tunnelManager.refreshAll()
                }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }

    // A tiny toolbar placed between SOCKS card and tunnel cards
    @ViewBuilder private var midControls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 8)
            Button("Load Config") { openAndLoadConfig() }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(isPresentingConfigPanel)
            Button("Stop All") { tunnelManager.stopAllTunnels() }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private var dynamicArea: some View {
        // Now returns plain content (no nested ScrollView)
        contentList
    }

    @ViewBuilder private var shortcutsPanel: some View {
        // Shortcuts panel (collapsible, placed above Logs)
        DisclosureGroup("Short Cuts") {
            // Remove inner ScrollView to avoid nested scrolling
            LazyVStack(alignment: .leading, spacing: 10) {
                // AWS grouped card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill((tunnelManager.groupState["aws"] ?? .idle) == .running ? Color.orange : (tunnelManager.groupState["aws"] == .success ? Color.green : (tunnelManager.groupState["aws"] == .failure ? Color.red : Color.gray)))
                            .frame(width: 8, height: 8)
                        Text("AWS")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if (tunnelManager.groupState["aws"] ?? .idle) == .running {
                            Button("Running…") {}
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .disabled(true)
                        } else {
                            Button("Run") {
                                guard !selectedAwsSystem.isEmpty, !selectedAwsEnv.isEmpty else { return }
                                tunnelManager.runGroup(kind: "aws", system: selectedAwsSystem, env: selectedAwsEnv)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(selectedAwsSystem.isEmpty || selectedAwsEnv.isEmpty)
                        }
                    }

                    Divider().opacity(0.12)

                    // Single-line selectors: System + Env
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            if tunnelManager.awsSystems.isEmpty {
                                Text("No systems found")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("System", selection: $selectedAwsSystem) {
                                    ForEach(tunnelManager.awsSystems, id: \.self) { s in
                                        Text(s).tag(s)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 220)
                            }

                            if tunnelManager.foundEnvs.isEmpty {
                                Text("No envs found")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Env", selection: $selectedAwsEnv) {
                                    ForEach(tunnelManager.foundEnvs, id: \.self) { e in
                                        Text(e).tag(e)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 120)
                            }
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                if let d = tunnelManager.groupLastRunAt["aws"] {
                                    Text("Last: \(d, formatter: dateFormatterSmall)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Never run").font(.caption2).foregroundStyle(.secondary)
                                }
                                if let code = tunnelManager.groupLastExit["aws"] {
                                    Text("Exit: \(code)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))

                // Kubernetes grouped card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill((tunnelManager.groupState["kubernetes"] ?? .idle) == .running ? Color.orange : (tunnelManager.groupState["kubernetes"] == .success ? Color.green : (tunnelManager.groupState["kubernetes"] == .failure ? Color.red : Color.gray)))
                            .frame(width: 8, height: 8)
                        Text("Kubernetes")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if (tunnelManager.groupState["kubernetes"] ?? .idle) == .running {
                            Button("Running…") {}
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                                .disabled(true)
                        } else {
                            Button("Run") {
                                guard !selectedK8sSystem.isEmpty, !selectedK8sEnv.isEmpty else { return }
                                tunnelManager.runGroup(kind: "kubernetes", system: selectedK8sSystem, env: selectedK8sEnv)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .disabled(selectedK8sSystem.isEmpty || selectedK8sEnv.isEmpty)
                        }
                    }

                    Divider().opacity(0.12)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            if tunnelManager.k8sSystems.isEmpty {
                                Text("No systems found")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("System", selection: $selectedK8sSystem) {
                                    ForEach(tunnelManager.k8sSystems, id: \.self) { s in
                                        Text(s).tag(s)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 220)
                            }

                            if tunnelManager.foundEnvs.isEmpty {
                                Text("No envs found")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Env", selection: $selectedK8sEnv) {
                                    ForEach(tunnelManager.foundEnvs, id: \.self) { e in
                                        Text(e).tag(e)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 120)
                            }
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                if let d = tunnelManager.groupLastRunAt["kubernetes"] {
                                    Text("Last: \(d, formatter: dateFormatterSmall)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Never run").font(.caption2).foregroundStyle(.secondary)
                                }
                                if let code = tunnelManager.groupLastExit["kubernetes"] {
                                    Text("Exit: \(code)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06), lineWidth: 1))

            }
            .padding(.vertical, 6)
            .onAppear {
                // set sensible defaults when lists are populated
                if selectedAwsSystem.isEmpty, let first = tunnelManager.awsSystems.first { selectedAwsSystem = first }
                if selectedAwsEnv.isEmpty, let first = tunnelManager.foundEnvs.first { selectedAwsEnv = first }
                if selectedK8sSystem.isEmpty, let first = tunnelManager.k8sSystems.first { selectedK8sSystem = first }
                if selectedK8sEnv.isEmpty, let first = tunnelManager.foundEnvs.first { selectedK8sEnv = first }
            }
            // When lists update after refresh, ensure selection is valid or set to first
            .onChange(of: tunnelManager.awsSystems) { _, new in
                if selectedAwsSystem.isEmpty || !new.contains(selectedAwsSystem) {
                    selectedAwsSystem = new.first ?? ""
                }
            }
            .onChange(of: tunnelManager.k8sSystems) { _, new in
                if selectedK8sSystem.isEmpty || !new.contains(selectedK8sSystem) {
                    selectedK8sSystem = new.first ?? ""
                }
            }
            .onChange(of: tunnelManager.foundEnvs) { _, new in
                if selectedAwsEnv.isEmpty || !new.contains(selectedAwsEnv) { selectedAwsEnv = new.first ?? "" }
                if selectedK8sEnv.isEmpty || !new.contains(selectedK8sEnv) { selectedK8sEnv = new.first ?? "" }
            }
        }
        .tint(.secondary)
    }

    @ViewBuilder private var logsPanel: some View {
        // Logs panel (collapsible, minimal impact on layout)
        DisclosureGroup(isExpanded: $showLogs) {
            logToolbar
            // Remove inner ScrollView; rely on outer ScrollView
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
        } label: {
            HStack(spacing: 6) {
                Text("Logs").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(tunnelManager.logEntries.count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .tint(.secondary)
    }

    // Version string sourced from Info.plist so it reflects MARKETING_VERSION and build
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "v\(short) (\(build))"
        }
        return "v\(short)"
    }

    var body: some View {
        // Single scroll container for the whole popover
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    // Header (constrained width)
                    headerBar
                    Divider().opacity(0.25)

                    dynamicArea

                    shortcutsPanel

                    logsPanel

                    // Footer: version info (bottom-left)
                    HStack(spacing: 6) {
                        Text(appVersionString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: maxContentWidth, alignment: .leading)
                .padding(16)
            }
        }
        // Width constraint only; height is scrollable
        .frame(maxWidth: maxContentWidth, alignment: .topLeading)
        // remove fileImporter on config
    }

    @ViewBuilder
    private var contentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            // SPAAS login control occupies the top row
            SpaasLoginCard()
                .frame(maxWidth: .infinity, alignment: .leading)

            SocksCard() // fixed SOCKS proxy control
                .frame(maxWidth: .infinity, alignment: .leading)

            // Insert the requested mid controls between the two cards
            if !tunnelManager.tunnels.isEmpty {
                midControls
            }

            // Tunnels list
            if tunnelManager.tunnels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No tunnels configured yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Load a config JSON…") { openAndLoadConfig() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
            } else {
                ForEach(tunnelManager.tunnels) { tunnel in
                    TunnelCard(tunnel: tunnel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    private var dateFormatterSmall: DateFormatter {
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.dateFormat = "HH:mm"; return df
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
        case .stderr: return "WRN"
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
        if isPresentingConfigPanel { return }
        isPresentingConfigPanel = true
        let panel = NSOpenPanel()
        panel.title = "Choose a config JSON"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json]
        // Temporarily promote app to regular to get a proper, draggable open panel
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        defer {
            // Return app to accessory menu bar mode
            NSApp.setActivationPolicy(.accessory)
            isPresentingConfigPanel = false
        }
        if response == .OK, let url = panel.url {
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
                ForEach(0..<(min(tunnel.localPorts.count, tunnel.remoteTargets.count)), id: \.self) { idx in
                    let lp = tunnel.localPorts[idx]
                    let target = tunnel.remoteTargets[idx]
                    HStack(spacing: 8) {
                        let status = tunnel.isActive ? tunnelManager.portStatus(for: lp) : .unknown
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

// Minimal SPAAS login card similar in style to TunnelCard/SocksCard
struct SpaasLoginCard: View {
    @EnvironmentObject var tunnelManager: TunnelManager
    @State private var showSpaasImporter: Bool = false
    @State private var isPresentingSpaasPanel: Bool = false

    private func stateColor() -> Color {
        switch tunnelManager.spaasState {
        case .idle: return Color.gray
        case .running: return Color.orange
        case .success: return Color.green
        case .failure: return Color.red
        }
    }

    private func stateText() -> String {
        switch tunnelManager.spaasState {
        case .idle: return "Idle"
        case .running: return "Running"
        case .success: return "Last run success"
        case .failure: return "Last run failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(stateColor())
                    .frame(width: 8, height: 8)
                Text("spaas login")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button("Load spaas…") { pickSpaas() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(isPresentingSpaasPanel)
                if tunnelManager.spaasState == .running {
                    Button("Running…") {}
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .disabled(true)
                } else {
                    Button("Run") { tunnelManager.spaasLogin() }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .disabled(!tunnelManager.spaasAvailable)
                }
            }

            Divider().opacity(0.12)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text("Path: \(tunnelManager.spaasPathDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stateText())
                            .font(.caption)
                        if let date = tunnelManager.spaasLastRunAt {
                            Text("Last: \(dateFormatter.string(from: date))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never run")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let code = tunnelManager.spaasLastExitStatus {
                            Text("Exit: \(code)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
        // remove .fileImporter for spaas
    }

    private var dateFormatter: DateFormatter {
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.dateFormat = "yyyy-MM-dd HH:mm:ss"; return df
    }

    private func pickSpaas() {
        if isPresentingSpaasPanel { return }
        isPresentingSpaasPanel = true
        let panel = NSOpenPanel()
        panel.title = "Select spaas executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin") {
            panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        }
        // Temporarily promote app to regular
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        defer {
            NSApp.setActivationPolicy(.accessory)
            isPresentingSpaasPanel = false
        }
        if response == .OK, let url = panel.url {
            tunnelManager.setSpaasPath(url)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TunnelManager())
    }
}
