import Foundation
import Combine

class TunnelManager: ObservableObject {
    @Published var tunnels: [TunnelConfig] = TunnelConfig.presets

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
        // Merge common paths to find Homebrew ssh if needed
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extras = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = current.split(separator: ":").map(String.init)
        for e in extras where !parts.contains(e) { parts.append(e) }
        return parts.joined(separator: ":")
    }

    init() {
        // Detect system state on launch so indicators reflect reality
        refreshStatusFromSystem()
    }

    func startTunnel(for tunnelID: UUID) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        let config = tunnels[index]
        guard processes[tunnelID] == nil else { return }

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
        writeLog("PATH=\(env["PATH"] ?? "")")

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
        } catch {
            let msg = "Failed to launch ssh: \(error.localizedDescription)"
            writeLog(msg)
            appendInMemory(level: .error, msg)
            tunnels[index].isActive = false
        }
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
                    if argsStr.contains("-L \(port):") || argsStr.contains("-L\(port):") {
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
            for t in snapshot {
                let allPortsListening = t.localPorts.allSatisfy { !self.pidsListening(onLocalPort: $0).isEmpty }
                statusByID[t.id] = allPortsListening
            }
            DispatchQueue.main.async {
                for i in self.tunnels.indices {
                    if let s = statusByID[self.tunnels[i].id] {
                        self.tunnels[i].isActive = s
                    }
                }
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
        }
    }

    func stopAllTunnels() {
        for (id, p) in processes { p.terminate(); processes[id] = nil }
        let allPorts = Array(Set(tunnels.flatMap { $0.localPorts }))
        for i in tunnels.indices { tunnels[i].isActive = false }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.systemKillForPorts(allPorts)
        }
    }
}
