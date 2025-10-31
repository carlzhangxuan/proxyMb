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

            // Monitor for spaas login success message in logs: if we see "spaas login exited with status 0"
            if message.contains("spaas login exited with status 0") {
                self.spaasLastExitStatus = 0
                self.spaasLastRunAt = Date()
                self.spaasState = .success
            }
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

    // Fixed SOCKS proxy (hardcoded): ssh -ND 0.0.0.0:1080 tunnel
    @Published var isSocksActive: Bool = false
    private var socksProcess: Process?
    private let socksPort: Int = 1080
    private let socksBind: String = "0.0.0.0:1080"
    private let socksHost: String = "tunnel"

    // SPAAS login monitoring
    enum SpaasState: Int { case idle = 0, running, success, failure }
    @Published var spaasState: SpaasState = .idle
    @Published var spaasLastExitStatus: Int? = nil
    @Published var spaasLastRunAt: Date? = nil
    private var spaasProcess: Process? = nil

    // Shortcuts (parsed from ~/.zshrc aliases)
    struct Shortcut: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let command: String
    }
    @Published var shortcuts: [Shortcut] = []
    // Track per-shortcut state and last run info keyed by shortcut name
    @Published var shortcutStates: [String: SpaasState] = [:]
    @Published var shortcutLastExit: [String: Int] = [:]
    @Published var shortcutLastRunAt: [String: Date] = [:]
    private var shortcutProcesses: [String: Process] = [:]

    // Structured shortcut groups (derived from aliases) - provide UI-friendly options
    @Published var awsSystems: [String] = []            // unique --system values for aws
    @Published var k8sSystems: [String] = []            // unique -s values for kubernetes
    @Published var foundEnvs: [String] = []             // unique env values (prd/dev etc)
    @Published var k8sContextBySystem: [String: String] = [:] // optional -C value per k8s system

    // Track running state for group-run operations (keys like "aws" and "kubernetes")
    @Published var groupState: [String: SpaasState] = ["aws": .idle, "kubernetes": .idle]
    @Published var groupLastExit: [String: Int] = [:]
    @Published var groupLastRunAt: [String: Date] = [:]
    private var groupProcesses: [String: Process] = [:]

    init() {
        // Load home config if present; then reflect system state and start monitor
        loadDefaultConfigIfPresent()
        loadShortcuts()
        refreshStatusFromSystem()
        startStatusMonitor()
    }

    deinit {
        stopStatusMonitor()
    }

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
        }

        do {
            try task.run()
            socksProcess = task
            isSocksActive = true
            writeLog("SOCKS ssh started (pid=\(task.processIdentifier))")
        } catch {
            let msg = "Failed to launch SOCKS ssh: \(error.localizedDescription)"
            writeLog(msg)
            appendInMemory(level: .error, msg)
            isSocksActive = false
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
            for t in snapshot {
                let allPortsListening = t.localPorts.allSatisfy { !self.pidsListening(onLocalPort: $0).isEmpty }
                statusByID[t.id] = allPortsListening
            }
            // Also refresh fixed SOCKS state
            let socksActive = !self.pidsListening(onLocalPort: self.socksPort).isEmpty
            DispatchQueue.main.async {
                for i in self.tunnels.indices {
                    if let s = statusByID[self.tunnels[i].id] {
                        self.tunnels[i].isActive = s
                    }
                }
                self.isSocksActive = socksActive
            }
        }
    }

    // Public helper to run `spaas login` and capture output into logs
    func spaasLogin() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            // Allow repeat runs: if a previous process exists but is not running, clear it; if running, ignore.
            if let p = self.spaasProcess {
                if p.isRunning {
                    self.appendInMemory(level: .info, "spaas login requested but already running")
                    return
                } else {
                    self.spaasProcess = nil
                }
            }

            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["spaas", "login"]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = self.defaultPATH()
            task.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            // mark running
            DispatchQueue.main.async {
                self.spaasState = .running
                self.spaasLastRunAt = Date()
            }
            self.spaasProcess = task

            let preview = (task.arguments ?? []).joined(separator: " ")
            self.writeLog("Launching: /usr/bin/env \(preview)")
            self.appendInMemory(level: .info, "Launching: spaas login")

            let capture: (FileHandle, LogLevel) -> Void = { [weak self] fh, lvl in
                fh.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                        let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.writeLog("[spaas \(lvl == .stdout ? "stdout" : "stderr")] \(line)")
                        self?.appendInMemory(level: lvl, line)
                    }
                }
            }
            capture(outPipe.fileHandleForReading, .stdout)
            capture(errPipe.fileHandleForReading, .stderr)

            task.terminationHandler = { [weak self] proc in
                guard let self = self else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                let status = proc.terminationStatus
                self.writeLog("spaas login exited with status \(status)")
                self.appendInMemory(level: status == 0 ? .info : .error, "spaas login exited with status \(status)")

                DispatchQueue.main.async {
                    self.spaasLastExitStatus = Int(status)
                    self.spaasProcess = nil
                    self.spaasState = (status == 0) ? .success : .failure
                }
            }

            do {
                try task.run()
            } catch {
                let msg = "Failed to launch spaas login: \(error.localizedDescription)"
                self.writeLog(msg)
                self.appendInMemory(level: .error, msg)
                DispatchQueue.main.async {
                    self.spaasLastExitStatus = -1
                    self.spaasProcess = nil
                    self.spaasState = .failure
                }
            }
        }
    }

    // MARK: - Shortcuts: load aliases from ~/.zshrc and run them
    func loadShortcuts() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let zshURL = self.homeDir().appendingPathComponent(".zshrc")
            var results: [Shortcut] = []
            if FileManager.default.fileExists(atPath: zshURL.path) {
                if let content = try? String(contentsOf: zshURL, encoding: .utf8) {
                    // Parse lines like: alias ll='ls -la'  or alias gs="git status"
                    let pattern = "^\\s*alias\\s+([A-Za-z0-9_+-]+)=['\"](.*?)['\"]\\s*$"
                    if let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                        let ns = content as NSString
                        let matches = re.matches(in: content, options: [], range: NSRange(location: 0, length: ns.length))
                        for m in matches {
                            if m.numberOfRanges >= 3 {
                                let name = ns.substring(with: m.range(at: 1))
                                let cmd = ns.substring(with: m.range(at: 2))
                                results.append(Shortcut(name: name, command: cmd))
                            }
                        }
                    }
                }
            }

            // Build structured groups from parsed shortcuts
            var awsSet = Set<String>()
            var k8sSet = Set<String>()
            var envSet = Set<String>()
            var k8sContextMap: [String: String] = [:]

            for sc in results {
                let cmd = sc.command
                // Normalize spacing to make regex simpler
                _ = cmd.replacingOccurrences(of: "=", with: " = ")

                if cmd.contains("spaas aws") {
                    // extract --system <value> and --env <value>
                    if let sys = firstMatch(in: cmd, pattern: "--system\\s+([\\S]+)") {
                        let s = sanitizeToken(sys)
                        awsSet.insert(s)
                    }
                    if let e = firstMatch(in: cmd, pattern: "--env\\s+([\\S]+)") {
                        let ev = sanitizeToken(e)
                        envSet.insert(ev)
                    }
                } else if cmd.contains("spaas kubernetes") || cmd.contains("spaas k8s") {
                    // extract -s <value>, -C <context>, and -A <env>
                    if let sys = firstMatch(in: cmd, pattern: "-s\\s+([\\S]+)") {
                        let s = sanitizeToken(sys)
                        k8sSet.insert(s)
                        if let ctx = firstMatch(in: cmd, pattern: "-C\\s+([\\S]+)") {
                            let c = sanitizeToken(ctx)
                            k8sContextMap[s] = c
                        }
                    }
                    if let e = firstMatch(in: cmd, pattern: "-A\\s+([\\S]+)") {
                        let ev = sanitizeToken(e)
                        envSet.insert(ev)
                    }
                }
            }

            let awsList = Array(awsSet).sorted()
            let k8sList = Array(k8sSet).sorted()
            let envList = Array(envSet).sorted()

            // Emit more detailed detection info to logs for visibility
            self.writeLog("Detected aws systems: \(awsList.joined(separator: ", "))")
            self.writeLog("Detected k8s systems: \(k8sList.joined(separator: ", "))")
            self.writeLog("Detected envs: \(envList.joined(separator: ", "))")

            DispatchQueue.main.async {
                 self.shortcuts = results
                 // initialize states
                 for s in results {
                     if self.shortcutStates[s.name] == nil {
                         self.shortcutStates[s.name] = .idle
                     }
                 }

                 // publish structured groups
                 self.awsSystems = awsList
                 self.k8sSystems = k8sList
                 self.foundEnvs = envList
                 self.k8sContextBySystem = k8sContextMap

                 // ensure group state entries exist
                 if self.groupState["aws"] == nil { self.groupState["aws"] = .idle }
                 if self.groupState["kubernetes"] == nil { self.groupState["kubernetes"] = .idle }
             }

            self.writeLog("Loaded shortcuts: \(results.count) from \(zshURL.path)")
        }
    }

    // Helper: return first capture group match
    private func firstMatch(in text: String, pattern: String) -> String? {
        if let re = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = text as NSString
            if let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges >= 2 {
                    return ns.substring(with: m.range(at: 1))
                }
            }
        }
        return nil
    }

    // Helper: sanitize tokens extracted from alias commands (strip quotes/parentheses)
    private func sanitizeToken(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimSet = CharacterSet(charactersIn: "\"'()")
        t = t.trimmingCharacters(in: trimSet)
        return t
    }

    // Run a grouped shortcut (aws or kubernetes) by composing a command from chosen parameters
    func runGroup(kind: String, system: String, env: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let key = kind // "aws" or "kubernetes"

            // Allow repeat runs: only block if an existing process is actually running.
            if let existing = self.groupProcesses[key] {
                if existing.isRunning {
                    self.appendInMemory(level: .info, "group \(key) run requested but already running")
                    return
                } else {
                    self.groupProcesses[key] = nil
                }
            }

            let task = Process()
            task.launchPath = "/usr/bin/env"
            var args: [String] = ["spaas"]
            if key == "aws" {
                args.append(contentsOf: ["aws", "configure", "--system", system, "--env", env])
            } else {
                // assume kubernetes
                args.append(contentsOf: ["kubernetes", "configure", "-s", system])
                if let ctx = self.k8sContextBySystem[system] { args.append(contentsOf: ["-C", ctx]) }
                args.append(contentsOf: ["-A", env])
            }
            task.arguments = args

            var envVars = ProcessInfo.processInfo.environment
            envVars["PATH"] = self.defaultPATH()
            task.environment = envVars

            let out = Pipe(); let err = Pipe()
            task.standardOutput = out; task.standardError = err

            DispatchQueue.main.async {
                self.groupState[key] = .running
                self.groupLastRunAt[key] = Date()
            }

            let preview = args.joined(separator: " ")
            self.writeLog("Launching group: /usr/bin/env \(preview)")
            self.appendInMemory(level: .info, "Launching group: \(key) system=\(system) env=\(env)")

            let capture: (FileHandle, LogLevel) -> Void = { [weak self] fh, lvl in
                fh.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                        let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.writeLog("[group \(key) \(lvl == .stdout ? "stdout" : "stderr")] \(line)")
                        self?.appendInMemory(level: lvl, line)
                    }
                }
            }
            capture(out.fileHandleForReading, .stdout)
            capture(err.fileHandleForReading, .stderr)

            task.terminationHandler = { [weak self] p in
                guard let self = self else { return }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let status = p.terminationStatus
                self.writeLog("group \(key) exited with status \(status)")
                self.appendInMemory(level: status == 0 ? .info : .error, "group \(key) exited with status \(status)")
                DispatchQueue.main.async {
                    self.groupLastExit[key] = Int(status)
                    self.groupProcesses[key] = nil
                    self.groupState[key] = (status == 0) ? .success : .failure
                }
            }

            do {
                try task.run()
                self.groupProcesses[key] = task
            } catch {
                let msg = "Failed to launch group \(key): \(error.localizedDescription)"
                self.writeLog(msg)
                self.appendInMemory(level: .error, msg)
                DispatchQueue.main.async {
                    self.groupLastExit[key] = -1
                    self.groupProcesses[key] = nil
                    self.groupState[key] = .failure
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

    // MARK: - Paths for config
    private func homeDir() -> URL { FileManager.default.homeDirectoryForCurrentUser }
    private func configDir() -> URL { homeDir().appendingPathComponent("ProxyMb", isDirectory: true) }
    private func homeConfigURL() -> URL { configDir().appendingPathComponent("config.json") }

    // MARK: - Config loading

    @Published var lastConfigURL: URL? = nil

    struct ExternalConfigItem: Codable {
        let endpoint: String // remote target "host:port"
        let port: Int        // local port
        let alias: String    // tunnel display name
        let sshHost: String? // optional ssh host alias, defaults to "tunnel"
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
                    // Ensure directory exists
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
                DispatchQueue.main.async {
                    self.stopAllTunnels()
                    self.tunnels = newTunnels
                    self.lastConfigURL = url
                    self.refreshStatusFromSystem()
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
