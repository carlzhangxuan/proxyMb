import Foundation
import Combine

class TunnelManager: ObservableObject {
    @Published var tunnels: [TunnelConfig] = []

    private var processes: [UUID: Process] = [:]

    // Logging (file + in-memory)
    enum LogLevel: String { case info, error, stdout, stderr }
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
    }
    @Published var logEntries: [LogEntry] = []

    // Track per-port listening status for UI (port -> status)
    @Published var portStatus: [Int: PortStatus] = [:]
    func portStatus(for port: Int) -> PortStatus { portStatus[port] ?? .unknown }

    // Periodic status monitor
    private var statusTimer: DispatchSourceTimer?

    private let logQueue = DispatchQueue(label: "ProxyMb.LogQueue")
    private lazy var logFileURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Logs/ProxyMb", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("ProxyMb.log")
    }()
    var logFileURLForUI: URL { logFileURL }

    private func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df.string(from: Date())
    }

    private func appendInMemory(level: LogLevel, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logEntries.append(LogEntry(timestamp: Date(), level: level, message: message))
            // Optional: keep last N
            if self.logEntries.count > 1000 { self.logEntries.removeFirst(self.logEntries.count - 1000) }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async { self.logEntries.removeAll() }
        // Optionally rotate file
        logQueue.async { [url = self.logFileURL] in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeLog(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        logQueue.async { [url = self.logFileURL] in
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let fh = try FileHandle(forWritingTo: url)
                    try fh.seekToEnd()
                    try fh.write(contentsOf: data)
                    try fh.close()
                } catch { /* ignore */ }
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func defaultPATH() -> String {
        // Merge common paths to find Homebrew ssh if needed, plus user bin dirs
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let extras = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            home + "/.local/bin",
            home + "/bin"
        ]
        var parts = current.split(separator: ":").map(String.init)
        for e in extras where !parts.contains(e) { parts.append(e) }
        return parts.joined(separator: ":")
    }

    // Ensure ~/.local/bin/spaas points to the chosen spaas so shells can find it
    @discardableResult
    private func ensureSpaasSymlink(target exeURL: URL?) -> Bool {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".local/bin", isDirectory: true)
        let link = dir.appendingPathComponent("spaas")
        do {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                writeLog("Created directory: \(dir.path)")
            }
            guard let exeURL = exeURL else { return false }
            // If existing and already correct, nothing to do
            if FileManager.default.fileExists(atPath: link.path) {
                // Try to read existing symlink destination
                let attrs = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
                let resolved = URL(fileURLWithPath: attrs, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
                if resolved.standardizedFileURL.path == exeURL.standardizedFileURL.path {
                    writeLog("spaas already discoverable at \(link.path) → \(exeURL.path)")
                    appendInMemory(level: .info, "spaas is already on PATH via ~/.local/bin/spaas")
                    return true
                } else {
                    // Remove and recreate
                    try FileManager.default.removeItem(at: link)
                }
            }
            // Create symlink
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exeURL)
            writeLog("Created symlink: \(link.path) → \(exeURL.path)")
            appendInMemory(level: .info, "Exported spaas to PATH via ~/.local/bin/spaas")
            return true
        } catch {
            // If it's a regular file or not a symlink, we don't overwrite; log hint
            appendInMemory(level: .error, "Failed to export spaas to PATH: \(error.localizedDescription)")
            writeLog("Failed to create symlink for spaas at \(link.path): \(error.localizedDescription)")
            return false
        }
    }

    // Fixed SOCKS proxy (hardcoded): ssh -ND 0.0.0.0:1080 tunnel
    @Published var isSocksActive: Bool = false
    private var socksProcess: Process?
    private let socksPort: Int = 1080
    private let socksBind: String = "0.0.0.0:1080"
    private let socksHost: String = "tunnel"
    // Track macOS system proxy state managed by the app
    @Published var isSystemProxyEnabled: Bool = false

    // MARK: - Spaas integration
    enum SpaasState { case idle, running, success, failure }
    @Published var spaasState: SpaasState = .idle
    @Published var spaasLastExitStatus: Int? = nil
    @Published var spaasLastRunAt: Date? = nil
    private var spaasProcess: Process? = nil

    // Grouped shortcuts (AWS/Kubernetes)
    @Published var groupState: [String: SpaasState] = [:] // reuse state enum
    @Published var groupLastRunAt: [String: Date] = [:]
    @Published var groupLastExit: [String: Int] = [:]

    // Simple data sources for pickers (can be populated from config later)
    @Published var awsSystems: [String] = []
    @Published var k8sSystems: [String] = []
    @Published var foundEnvs: [String] = []

    // Persisted custom path selected by user
    private let spaasCustomPathKey = "SpaasCustomPath"
    @Published var spaasCustomPath: URL? = nil

    // Resolve spaas path: prefer custom path, then typical locations, then PATH via which
    func resolveSpaasURL() -> URL? {
        // Custom path
        if let u = spaasCustomPath, FileManager.default.isExecutableFile(atPath: u.path) {
            return u
        }
        // Typical install locations
        let candidates = [
            "/usr/local/bin/spaas",
            "/opt/homebrew/bin/spaas",
            "/usr/bin/spaas",
            "/bin/spaas",
            (NSHomeDirectory() + "/.local/bin/spaas")
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        // PATH via which
        let (out, code) = runCommand("/usr/bin/which", ["spaas"])
        if code == 0 {
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    var spaasAvailable: Bool { resolveSpaasURL() != nil }

    var spaasPathDescription: String {
        if let u = spaasCustomPath, FileManager.default.isExecutableFile(atPath: u.path) {
            return "custom: \(u.path)"
        }
        if let u = resolveSpaasURL() {
            return "system: \(u.path)"
        }
        return "not found"
    }

    func setSpaasPath(_ url: URL) {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            writeLog("Selected spaas is not executable: \(url.path)")
            appendInMemory(level: .error, "spaas not executable: \(url.lastPathComponent)")
            return
        }
        spaasCustomPath = url
        UserDefaults.standard.set(url.path, forKey: spaasCustomPathKey)
        writeLog("Set custom spaas path: \(url.path)")
        appendInMemory(level: .info, "Set custom spaas: \(url.lastPathComponent)")
        // Make it discoverable for shells: ~/.local/bin/spaas → selected path
        let ok = ensureSpaasSymlink(target: url)
        if !ok {
            appendInMemory(level: .stderr, "Tip: add to your shell rc, e.g., export PATH=\"$HOME/.local/bin:$PATH\"")
        }
    }

    func clearSpaasPath() {
        spaasCustomPath = nil
        UserDefaults.standard.removeObject(forKey: spaasCustomPathKey)
        writeLog("Cleared custom spaas path")
    }

    func spaasLogin() {
        // Avoid duplicate runs
        if let p = spaasProcess, p.isRunning {
            writeLog("spaas already running (pid=\(p.processIdentifier))")
            return
        }
        guard let exeURL = resolveSpaasURL() else {
            let msg = "spaas executable not found (set custom path or install to PATH)"
            writeLog(msg)
            appendInMemory(level: .error, msg)
            DispatchQueue.main.async {
                self.spaasLastExitStatus = nil
                self.spaasLastRunAt = Date()
                self.spaasState = .failure
            }
            return
        }
        let task = Process()
        task.launchPath = exeURL.path
        task.arguments = ["login"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = defaultPATH()
        task.environment = env

        let out = Pipe(); let err = Pipe()
        task.standardOutput = out; task.standardError = err

        let capture: (FileHandle, LogLevel) -> Void = { [weak self] h, lvl in
            h.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty { return }
                if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                    let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.writeLog("[spaas \(lvl == .stdout ? "stdout" : "stderr")] \(line)")
                    self?.appendInMemory(level: lvl, line)
                }
            }
        }
        capture(out.fileHandleForReading, .stdout)
        capture(err.fileHandleForReading, .stderr)

        task.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = Int(p.terminationStatus)
            self?.writeLog("spaas login exited with status \(status)")
            DispatchQueue.main.async {
                self?.spaasProcess = nil
                self?.spaasLastExitStatus = status
                self?.spaasLastRunAt = Date()
                self?.spaasState = (status == 0 ? .success : .failure)
            }
        }

        do {
            let preview = "\(exeURL.path) login"
            writeLog("Launching spaas: \(preview)")
            appendInMemory(level: .info, "Launching spaas: \(preview)")
            try task.run()
            spaasProcess = task
            DispatchQueue.main.async { self.spaasState = .running }
            writeLog("spaas started (pid=\(task.processIdentifier))")
        } catch {
            let msg = "Failed to launch spaas: \(error.localizedDescription)"
            writeLog(msg)
            appendInMemory(level: .error, msg)
            DispatchQueue.main.async { self.spaasState = .failure }
        }
    }

    func spaasStop() {
        if let p = spaasProcess {
            p.terminate()
            spaasProcess = nil
            writeLog("Terminated spaas process")
        }
        DispatchQueue.main.async { self.spaasState = .idle }
    }

    // Run a logical group (aws/kubernetes) — placeholder implementation
    func runGroup(kind: String, system: String, env: String) {
        DispatchQueue.main.async {
            self.groupState[kind] = .running
            self.groupLastRunAt[kind] = Date()
        }
        writeLog("Run group: kind=\(kind) system=\(system) env=\(env)")
        appendInMemory(level: .info, "Run group (\(kind)): \(system) / \(env)")
        // Simulate a quick success; replace with real orchestration as needed
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.groupLastExit[kind] = 0
                self.groupState[kind] = .success
            }
            self.writeLog("Group \(kind) completed with exit 0")
        }
    }

    init() {
        // Restore custom spaas path if present
        if let p = UserDefaults.standard.string(forKey: spaasCustomPathKey) {
            let url = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: url.path) {
                spaasCustomPath = url
            }
        }
        // Seed pickers lightly (optional)
        if awsSystems.isEmpty { awsSystems = [] }
        if k8sSystems.isEmpty { k8sSystems = [] }
        if foundEnvs.isEmpty { foundEnvs = [] }
        // Load home config if present; then reflect system state and start monitor
        loadDefaultConfigIfPresent()
        refreshStatusFromSystem()
        startStatusMonitor()
    }

    deinit { stopStatusMonitor() }

    // Start periodic monitoring to auto-detect externally-started tunnels
    private func startStatusMonitor(interval: TimeInterval = 3.0) {
        guard statusTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.refreshStatusFromSystem()
        }
        timer.resume()
        statusTimer = timer
        writeLog("Started status monitor (every \(interval)s)")
    }

    private func stopStatusMonitor() {
        statusTimer?.setEventHandler(handler: nil)
        statusTimer?.cancel()
        statusTimer = nil
        writeLog("Stopped status monitor")
    }

    // Soft refresh: stop processes, reset states, reload config/status
    func refreshAll() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.writeLog("Refreshing all state…")

            // Stop spaas if running
            if let p = self.spaasProcess, p.isRunning { p.terminate() }
            self.spaasProcess = nil

            // Stop SOCKS and all tunnels
            self.stopSocks()
            self.stopAllTunnels()

            // Reset spaas and group states
            DispatchQueue.main.async {
                self.spaasState = .idle
                self.spaasLastExitStatus = nil
                self.spaasLastRunAt = nil
                self.groupState.removeAll()
                self.groupLastRunAt.removeAll()
                self.groupLastExit.removeAll()
            }

            // Reload config and refresh status
            self.loadDefaultConfigIfPresent()
            self.refreshStatusFromSystem()
            self.writeLog("Refresh complete")
        }
    }

    func startTunnel(for tunnelID: UUID) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        let config = tunnels[index]
        guard processes[tunnelID] == nil else { return }
        // Validate mapping counts
        guard config.localPorts.count == config.remoteTargets.count else {
            let msg = "Config mismatch for \(config.name): localPorts(\(config.localPorts.count)) != remoteTargets(\(config.remoteTargets.count))"
            writeLog(msg)
            appendInMemory(level: .error, msg)
            return
        }

        let task = Process()
        // Use /usr/bin/env to resolve ssh via PATH
        task.launchPath = "/usr/bin/env"

        var args: [String] = ["ssh", "-N", "-o", "ExitOnForwardFailure=yes"]
        for (lp, target) in zip(config.localPorts, config.remoteTargets) {
            args.append(contentsOf: ["-L", "\(lp):\(target)"])
        }
        args.append(config.sshHost)
        task.arguments = args

        // Ensure PATH contains common locations (Homebrew)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = defaultPATH()
        task.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        // Log command preview
        let cmdPreview = args.joined(separator: " ")
        writeLog("Launching ssh: \(cmdPreview)")
        appendInMemory(level: .info, "Launching ssh: \(cmdPreview)")
        let pathPreview = env["PATH"] ?? ""
        writeLog("PATH=\(pathPreview)")

        let capture: (FileHandle, LogLevel) -> Void = { [weak self] handle, level in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty { return }
                if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                    let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.writeLog("[\(level == .stdout ? "stdout" : "stderr")] \(line)")
                    self?.appendInMemory(level: level, line)
                }
            }
        }
        capture(outputPipe.fileHandleForReading, .stdout)
        capture(errorPipe.fileHandleForReading, .stderr)

        task.terminationHandler = { [weak self] proc in
            // Stop capturing
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            self?.writeLog("ssh exited with status \(status)")
            self?.appendInMemory(level: status == 0 ? .info : .error, "ssh exited with status \(status)")
            DispatchQueue.main.async {
                self?.processes[tunnelID] = nil
                if let idx = self?.tunnels.firstIndex(where: { $0.id == tunnelID }) {
                    self?.tunnels[idx].isActive = false
                }
            }
        }

        do {
            try task.run()
            processes[tunnelID] = task
            tunnels[index].isActive = true
            writeLog("ssh started (pid=\(task.processIdentifier)) for tunnel=\(config.name)")
            appendInMemory(level: .info, "ssh started (pid=\(task.processIdentifier)) for \(config.name)")
            // Immediately refresh UI port statuses
            refreshStatusFromSystem()
        } catch {
            let msg = "Failed to launch ssh: \(error.localizedDescription)"
            writeLog(msg)
            appendInMemory(level: .error, msg)
            tunnels[index].isActive = false
        }
    }

    // MARK: - macOS System Proxy (SOCKS) helpers

    private func listNetworkServices() -> [String] {
        let tool = "/usr/sbin/networksetup"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return [] }
        let (out, code) = runCommand(tool, ["-listallnetworkservices"])
        guard code == 0 else { return [] }
        var result: [String] = []
        for (idx, raw) in out.split(separator: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if idx == 0 && line.lowercased().contains("asterisk") { continue } // header
            if line.isEmpty { continue }
            if line.hasPrefix("*") { continue } // disabled service
            result.append(line)
        }
        return result
    }

    private func applySystemSocksProxy(enable: Bool, host: String = "127.0.0.1", port: Int? = nil) {
        let p = port ?? socksPort
        let tool = "/usr/sbin/networksetup"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            writeLog("networksetup not found; cannot update system proxy")
            return
        }
        let services = listNetworkServices()
        if services.isEmpty {
            writeLog("No network services found to apply system proxy")
        }
        DispatchQueue.global(qos: .utility).async {
            for svc in services {
                if enable {
                    let (_, c1) = self.runCommand(tool, ["-setsocksfirewallproxy", svc, host, String(p)])
                    let (_, c2) = self.runCommand(tool, ["-setsocksfirewallproxystate", svc, "on"])
                    if c1 == 0 && c2 == 0 {
                        self.writeLog("Enabled system SOCKS for [\(svc)] → \(host):\(p)")
                    } else {
                        self.writeLog("Failed to enable system SOCKS for [\(svc)] (codes: \(c1)/\(c2))")
                    }
                } else {
                    let (_, c) = self.runCommand(tool, ["-setsocksfirewallproxystate", svc, "off"])
                    if c == 0 { self.writeLog("Disabled system SOCKS for [\(svc)]") }
                    else { self.writeLog("Failed to disable system SOCKS for [\(svc)] (code: \(c))") }
                }
            }
            DispatchQueue.main.async { self.isSystemProxyEnabled = enable }
        }
    }

    // Start hardcoded SOCKS proxy
    func startSocks() {
        guard socksProcess == nil else { return }
        let task = Process()
        task.launchPath = "/usr/bin/env"
        let args: [String] = ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-D", socksBind, socksHost]
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = defaultPATH()
        task.environment = env

        let out = Pipe(); let err = Pipe()
        task.standardOutput = out; task.standardError = err

        writeLog("Launching SOCKS: \(args.joined(separator: " "))")
        appendInMemory(level: .info, "Launching SOCKS: \(args.joined(separator: " "))")

        let capture: (FileHandle, LogLevel) -> Void = { [weak self] h, lvl in
            h.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty { return }
                if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                    let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.writeLog("[SOCKS \(lvl == .stdout ? "stdout" : "stderr")] \(line)")
                    self?.appendInMemory(level: lvl, line)
                }
            }
        }
        capture(out.fileHandleForReading, .stdout)
        capture(err.fileHandleForReading, .stderr)

        task.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            self?.writeLog("SOCKS ssh exited with status \(p.terminationStatus)")
            DispatchQueue.main.async {
                self?.socksProcess = nil
                self?.isSocksActive = false
            }
            // Ensure system proxy is turned off on unexpected exit
            self?.applySystemSocksProxy(enable: false)
        }

        do {
            try task.run()
            socksProcess = task
            isSocksActive = true
            writeLog("SOCKS ssh started (pid=\(task.processIdentifier))")
            // Enable macOS system proxy to route traffic via local SOCKS
            applySystemSocksProxy(enable: true, host: "127.0.0.1", port: socksPort)
        } catch {
            let msg = "Failed to launch SOCKS ssh: \(error.localizedDescription)"
            writeLog(msg)
            appendInMemory(level: .error, msg)
            isSocksActive = false
            applySystemSocksProxy(enable: false)
        }
    }

    func stopSocks() {
        if let p = socksProcess {
            p.terminate()
            socksProcess = nil
        }
        isSocksActive = false
        // System-level cleanup for port 1080
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.systemKillForPorts([self?.socksPort ?? 1080])
        }
        // Disable macOS system proxy
        applySystemSocksProxy(enable: false)
    }

    private func refreshSocksStatus() {
        let active = !pidsListening(onLocalPort: socksPort).isEmpty
        DispatchQueue.main.async { self.isSocksActive = active }
    }

    // MARK: - System-level helpers

    private func runCommand(_ path: String, _ args: [String]) -> (String, Int32) {
        let proc = Process()
        proc.launchPath = path
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        do { try proc.run() } catch { return ("", -1) }
        proc.waitUntilExit()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? ""
        return (str, proc.terminationStatus)
    }

    private func pidsListening(onLocalPort port: Int) -> Set<Int32> {
        var pids = Set<Int32>()
        let lsofPath = "/usr/sbin/lsof"
        if FileManager.default.isExecutableFile(atPath: lsofPath) {
            let (out, _) = runCommand(lsofPath, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpct"])
            var lastPid: Int32? = nil
            var lastCmd: String = ""
            for line in out.split(separator: "\n") {
                if line.first == "p", let v = Int32(line.dropFirst()) { lastPid = v }
                else if line.first == "c" { lastCmd = String(line.dropFirst()) }
                if let pid = lastPid, !lastCmd.isEmpty {
                    if lastCmd.contains("ssh") { pids.insert(pid) }
                    lastPid = nil; lastCmd = ""
                }
            }
        }
        if pids.isEmpty {
            let (s, _) = runCommand("/bin/ps", ["-axo", "pid=,args="])
            for line in s.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
                let pidStr = trimmed[..<spaceIdx]
                let argsStr = trimmed[spaceIdx...]
                if argsStr.contains(" ssh") || argsStr.contains("/ssh") || argsStr.contains(" sshd") {
                    // Match -L <port>: or -L<port>:
                    let hasL = argsStr.contains("-L \(port):") || argsStr.contains("-L\(port):")
                    // Match SOCKS: -D <port> or -D<port>
                    let hasD = argsStr.contains("-D \(port)") || argsStr.contains("-D\(port)")
                    if hasL || hasD {
                        if let pid = Int32(pidStr) { pids.insert(pid) }
                    }
                }
            }
        }
        return pids
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        let (_, status) = runCommand("/bin/kill", ["-0", String(pid)])
        return status == 0
    }

    private func sendSignal(_ signal: String, to pid: Int32) {
        _ = runCommand("/bin/kill", ["-\(signal)", String(pid)])
    }

    private func terminate(pids: Set<Int32>, timeout: TimeInterval = 1.0) {
        guard !pids.isEmpty else { return }
        for pid in pids { sendSignal("TERM", to: pid) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            for pid in pids where self.isProcessAlive(pid) { self.sendSignal("KILL", to: pid) }
        }
    }

    private func systemKillForPorts(_ ports: [Int]) {
        var allPids = Set<Int32>()
        for p in ports { allPids.formUnion(pidsListening(onLocalPort: p)) }
        terminate(pids: allPids)
    }

    // New: refresh tunnels active state from current system listeners
    func refreshStatusFromSystem() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var statusByID: [UUID: Bool] = [:]
            // Snapshot tunnels to avoid mutation while iterating
            let snapshot = self.tunnels
            // Aggregate unique local ports for per-port status
            var uniquePorts = Set<Int>()
            for t in snapshot {
                uniquePorts.formUnion(t.localPorts)
                let allPortsListening = t.localPorts.allSatisfy { !self.pidsListening(onLocalPort: $0).isEmpty }
                statusByID[t.id] = allPortsListening
            }
            // Also include SOCKS port in port status tracking
            uniquePorts.insert(self.socksPort)
            // Compute per-port status
            var newPortStatus: [Int: PortStatus] = [:]
            for p in uniquePorts {
                let listening = !self.pidsListening(onLocalPort: p).isEmpty
                newPortStatus[p] = listening ? .listening : .notListening
            }
            // Also refresh fixed SOCKS state
            let socksActive = (newPortStatus[self.socksPort] == .listening)
            DispatchQueue.main.async {
                for i in self.tunnels.indices {
                    if let s = statusByID[self.tunnels[i].id] {
                        self.tunnels[i].isActive = s
                    }
                }
                self.isSocksActive = socksActive
                self.portStatus = newPortStatus
            }
        }
    }

    // MARK: - Public stop APIs (non-blocking)

    func stopTunnel(for tunnelID: UUID) {
        if let p = processes[tunnelID] {
            p.terminate()
            processes[tunnelID] = nil
        }
        guard let idx = tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        let ports = tunnels[idx].localPorts
        tunnels[idx].isActive = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.systemKillForPorts(ports)
            // Refresh UI after stopping and cleanup
            DispatchQueue.main.async { self?.refreshStatusFromSystem() }
        }
    }

    func stopAllTunnels() {
        for (id, p) in processes { p.terminate(); processes[id] = nil }
        let allPorts = Array(Set(tunnels.flatMap { $0.localPorts }))
        for i in tunnels.indices { tunnels[i].isActive = false }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.systemKillForPorts(allPorts)
            // Refresh UI after mass stop
            DispatchQueue.main.async { self?.refreshStatusFromSystem() }
        }
    }

    // New: soft stop that only terminates tracked processes without port sweeping
    func stopAllTunnelsSoft() {
        for (id, p) in processes { p.terminate(); processes[id] = nil }
        for i in tunnels.indices { tunnels[i].isActive = false }
        writeLog("Soft-stopped all tunnels (no port sweep)")
    }

    // MARK: - Paths for config
    private func homeDir() -> URL { FileManager.default.homeDirectoryForCurrentUser }
    private func configDir() -> URL { homeDir().appendingPathComponent("ProxyMb", isDirectory: true) }
    private func homeConfigURL() -> URL { configDir().appendingPathComponent("config.json") }

    // MARK: - Config loading

    @Published var lastConfigURL: URL? = nil

    struct ExternalConfigItem: Decodable {
        let endpoint: String // remote target "host:port"
        let port: Int        // local port
        let alias: String    // tunnel display name
        let sshHost: String? // optional ssh host alias, defaults to "tunnel"

        enum CodingKeys: String, CodingKey {
            case endpoint, port, alias, sshHost
            // synonyms supported for backwards compatibility
            case remote, target
            case name, label, title
            case ssh
        }

        init(endpoint: String, port: Int, alias: String, sshHost: String?) {
            self.endpoint = endpoint
            self.port = port
            self.alias = alias
            self.sshHost = sshHost
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // endpoint: endpoint | remote | target
            let endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
                ?? c.decodeIfPresent(String.self, forKey: .remote)
                ?? c.decodeIfPresent(String.self, forKey: .target)
            // alias: alias | name | label | title
            let alias = try c.decodeIfPresent(String.self, forKey: .alias)
                ?? c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .label)
                ?? c.decodeIfPresent(String.self, forKey: .title)
            // port
            let port = try c.decodeIfPresent(Int.self, forKey: .port)
            // sshHost: sshHost | ssh
            let sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost)
                ?? c.decodeIfPresent(String.self, forKey: .ssh)
            guard let endpointUnwrapped = endpoint, let aliasUnwrapped = alias, let portUnwrapped = port else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Missing required fields (endpoint/alias/port)"))
            }
            self.endpoint = endpointUnwrapped
            self.alias = aliasUnwrapped
            self.port = portUnwrapped
            self.sshHost = sshHost
        }
    }

    private func makeTunnels(from items: [ExternalConfigItem]) -> [TunnelConfig] {
        items.map { it in
            TunnelConfig(
                name: it.alias,
                localPorts: [it.port],
                remoteTargets: [it.endpoint],
                sshHost: it.sshHost ?? "tunnel",
                isActive: false
            )
        }
    }

    private func decodeConfigItems(from data: Data) throws -> [ExternalConfigItem] {
        try JSONDecoder().decode([ExternalConfigItem].self, from: data)
    }

    // Load a config and optionally save a copy to ~/ProxyMb/config.json when it's not the same file
    func loadConfig(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try Data(contentsOf: url)
                let items = try self.decodeConfigItems(from: data)
                let newTunnels = self.makeTunnels(from: items)

                // If source is not the home config path, save a copy there
                let homeURL = self.homeConfigURL()
                if url.standardizedFileURL.path != homeURL.standardizedFileURL.path {
                    if !FileManager.default.fileExists(atPath: self.configDir().path) {
                        try? FileManager.default.createDirectory(at: self.configDir(), withIntermediateDirectories: true)
                    }
                    do {
                        try data.write(to: homeURL, options: .atomic)
                        self.writeLog("Saved uploaded config to \(homeURL.path)")
                    } catch {
                        self.writeLog("Failed to save uploaded config to \(homeURL.path): \(error.localizedDescription)")
                    }
                }

                self.writeLog("Loaded config from: \(url.path) (items=\(items.count))")
                self.appendInMemory(level: .info, "Loaded config: \(items.count) items")

                // Apply without touching existing processes; UI should reflect live status
                DispatchQueue.main.async {
                    self.tunnels = newTunnels
                    self.lastConfigURL = url
                    self.refreshStatusFromSystem()
                    self.writeLog("Applied config to UI (no auto start/stop)")
                }
            } catch {
                self.appendInMemory(level: .error, "Failed to load config from \(url.lastPathComponent): \(error.localizedDescription)")
                self.writeLog("Failed to load config from \(url.path): \(error.localizedDescription)")
            }
        }
    }

    // On launch, try ~/ProxyMb/config.json; if missing, leave empty and log guidance
    func loadDefaultConfigIfPresent() {
        let u = homeConfigURL()
        if FileManager.default.fileExists(atPath: u.path) {
            loadConfig(from: u)
        } else {
            writeLog("No ~/ProxyMb/config.json found; tunnels list is empty. Use 'Load Config' to import a JSON.")
            DispatchQueue.main.async {
                self.stopAllTunnels()
                self.tunnels = []
                self.lastConfigURL = nil
                self.refreshStatusFromSystem()
            }
        }
    }
}
