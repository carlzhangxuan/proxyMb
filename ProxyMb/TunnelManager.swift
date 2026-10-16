import Foundation
import Combine

class TunnelManager: ObservableObject {
    // Runtime/UI state is confined to the main queue. Only immutable snapshots
    // cross to the worker queue; log buffers have their own serial queues.
    @Published var tunnels: [TunnelConfig] = []
    @Published private(set) var stoppingPorts: Set<Int> = []

    private(set) var processes: [UUID: Process] = [:]
    let systemQueue = DispatchQueue(label: "ProxyMb.System", qos: .utility)
    private var statusGeneration = 0
    private var statusRefreshInFlight = false
    private var isShuttingDown = false
    private var listenerPIDs: [Int: Set<Int32>] = [:]
    private let homeDirectory: URL
    private let environment: [String: String]
    private let networkSetupExecutable: String
    private let lsofExecutable: String

    // Logging (file + in-memory)
    enum LogLevel: String { case info, error, stdout, stderr }
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
    }
    @Published var logEntries: [LogEntry] = []

    // Cap log array and trim in batches to avoid frequent front-removals
    private let logMaxEntries: Int = 1000
    private let logTrimBatch: Int = 200

    // Buffer logs and flush periodically to minimize UI updates
    private var pendingLogEntries: [LogEntry] = []
    private let logUIBufferQueue = DispatchQueue(label: "ProxyMb.LogUIBuffer")
    private var logFlushTimer: DispatchSourceTimer?

    // Periodic status monitor
    private var statusTimer: DispatchSourceTimer?

    private let logQueue = DispatchQueue(label: "ProxyMb.LogQueue")
    private let logFileURL: URL
    var logFileURLForUI: URL { logFileURL }

    private func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df.string(from: Date())
    }

    // MARK: - SPAAS binary management (remote feature)

    @Published var spaasAvailable: Bool = false
    private let spaasPathDefaultsKey = "ProxyMb.spaasPath"
    private var spaasCustomURL: URL? = nil

    var spaasPathDescription: String {
        if let u = spaasCustomURL { return "custom: \(u.path)" }
        if let sys = resolveSpaasURL()?.path { return "system: \(sys)" }
        return "system: (not found)"
    }

    // Ensure a file is executable; if not, try to add +x for user (best effort)
    private func ensureExecutable(at url: URL) -> Bool {
        let path = url.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        if fm.isExecutableFile(atPath: path) { return true }
        // Try to chmod +x (u+x or 0755)
        do {
            let attrs = try fm.attributesOfItem(atPath: path)
            if let perm = attrs[.posixPermissions] as? NSNumber {
                let current = perm.uint16Value
                let desired: UInt16 = current | 0o111 // add execute bits
                if desired != current {
                    try fm.setAttributes([.posixPermissions: NSNumber(value: desired)], ofItemAtPath: path)
                }
            } else {
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: path)
            }
        } catch {
            // Best effort; ignore
        }
        return fm.isExecutableFile(atPath: path)
    }

    func setSpaasPath(_ url: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Accept selected file; try to ensure it's executable, but don't block if chmod fails
        let ok = ensureExecutable(at: url)
        if !ok {
            appendInMemory(level: .stderr, "Selected spaas not executable yet; attempted to add +x: \(url.path)")
        }
        spaasCustomURL = url
        UserDefaults.standard.set(url.path, forKey: spaasPathDefaultsKey)
        let available = (resolveSpaasURL() != nil)
        DispatchQueue.main.async { self.spaasAvailable = available }
        appendInMemory(level: .info, "Using custom spaas: \(url.path)")
    }

    private func loadSpaasPathFromDefaults() {
        if let p = UserDefaults.standard.string(forKey: spaasPathDefaultsKey) {
            let u = URL(fileURLWithPath: p)
            let fm = FileManager.default
            if fm.fileExists(atPath: u.path) {
                spaasCustomURL = fm.isExecutableFile(atPath: u.path) ? u : nil
            } else {
                spaasCustomURL = nil
            }
        }
        // Update availability based on custom or system path
        let available = (resolveSpaasURL() != nil)
        DispatchQueue.main.async { self.spaasAvailable = available }
    }

    // Availability and launch use the exact same executable and expanded PATH.
    func resolveSpaasURL() -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        var candidates = [URL]()
        if let custom = spaasCustomURL { candidates.append(custom) }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/spaas"))
        }
        candidates += defaultPATH().split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("spaas")
        }
        return candidates.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    // Enqueue a log entry into the pending buffer (thread-safe)
    private func appendInMemory(level: LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logUIBufferQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingLogEntries.append(entry)
        }
    }

    // Periodic flusher that batches pending entries into the published array
    private func startLogFlushTimer(interval: TimeInterval = 0.2) {
        guard logFlushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: logUIBufferQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard !self.pendingLogEntries.isEmpty else { return }
            let batch = self.pendingLogEntries
            self.pendingLogEntries.removeAll(keepingCapacity: true)
            DispatchQueue.main.async {
                self.logEntries.append(contentsOf: batch)
                let over = self.logEntries.count - self.logMaxEntries
                if over > self.logTrimBatch {
                    self.logEntries.removeFirst(over)
                }
            }
        }
        timer.resume()
        logFlushTimer = timer
    }

    private func stopLogFlushTimer() {
        logFlushTimer?.setEventHandler(handler: nil)
        logFlushTimer?.cancel()
        logFlushTimer = nil
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
        // Merge common paths to find Homebrew ssh/spaas if needed, plus user bin dirs
        let current = environment["PATH"] ?? ""
        let home = homeDirectory.path
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

    // Fixed SOCKS proxy (hardcoded): ssh -ND 0.0.0.0:1080 tunnel
    @Published var isSocksActive: Bool = false
    private(set) var socksProcess: Process?
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
    @Published var awsSystems: [String] = []
    @Published var k8sSystems: [String] = []
    @Published var foundEnvs: [String] = []
    @Published var k8sContextBySystem: [String: String] = [:]

    // Track running state for group-run operations (keys like "aws" and "kubernetes")
    @Published var groupState: [String: SpaasState] = ["aws": .idle, "kubernetes": .idle]
    @Published var groupLastExit: [String: Int] = [:]
    @Published var groupLastRunAt: [String: Date] = [:]
    private var groupProcesses: [String: Process] = [:]

    // Per-port listening cache used by UI portStatus
    private var portListeningCache: [Int: Bool] = [:]

    init(startRuntime: Bool = true,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         networkSetupExecutable: String = "/usr/sbin/networksetup",
         lsofExecutable: String = "/usr/sbin/lsof") {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.networkSetupExecutable = networkSetupExecutable
        self.lsofExecutable = lsofExecutable
        let logDirectory = homeDirectory.appendingPathComponent("Library/Logs/ProxyMb")
        self.logFileURL = logDirectory.appendingPathComponent("ProxyMb.log")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        guard startRuntime else { return }
        dispatchPrecondition(condition: .onQueue(.main))
        // Load home config if present; then reflect system state and start monitor
        loadDefaultConfigIfPresent()
        loadShortcuts()
        loadSpaasPathFromDefaults()
        refreshStatusFromSystem()
        startStatusMonitor()
        startLogFlushTimer()
    }

    deinit {
        stopStatusMonitor()
        stopLogFlushTimer()
    }

    // Start periodic monitoring to auto-detect externally-started tunnels
    private func startStatusMonitor(interval: TimeInterval = 3.0) {
        guard statusTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
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

    // Reset runtime state similar to app restart and reload config/shortcuts
    func refreshAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.isShuttingDown else { return }
            self.statusGeneration += 1
            self.writeLog("Refreshing all state (soft restart)…")

            // Pause periodic monitor to avoid races while resetting
            self.stopStatusMonitor()

            let commands = Array(self.groupProcesses.values) + [self.spaasProcess].compactMap { $0 }
            self.systemQueue.async { self.terminateOwnedProcesses(commands) }

            // Clear references
            self.spaasProcess = nil
            self.groupProcesses.removeAll()

            // Stop SOCKS and tunnels
            self.stopSocks()
            self.stopAllTunnels()

            // Reset published states and in-memory logs (do not delete log file)
            self.isSocksActive = false
            self.spaasState = .idle
            self.spaasLastExitStatus = nil
            self.spaasLastRunAt = nil

            self.groupState["aws"] = .idle
            self.groupState["kubernetes"] = .idle
            self.groupLastExit.removeAll()
            self.groupLastRunAt.removeAll()

            self.shortcuts.removeAll()
            self.awsSystems.removeAll()
            self.k8sSystems.removeAll()
            self.foundEnvs.removeAll()
            self.k8sContextBySystem.removeAll()

            self.shortcutStates.removeAll()
            self.shortcutLastExit.removeAll()
            self.shortcutLastRunAt.removeAll()

            self.logEntries.removeAll()
            self.lastConfigURL = nil

            // Reload from disk
            self.loadDefaultConfigIfPresent()
            self.loadShortcuts()
            self.loadSpaasPathFromDefaults()
            self.refreshStatusFromSystem()

            // Resume monitor after state is consistent
            self.startStatusMonitor()
            self.writeLog("Refresh complete")
        }
    }

    func startTunnel(for tunnelID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown else { return }
        guard let index = tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        let config = tunnels[index]
        guard stoppingPorts.isDisjoint(with: config.localPorts) else { return }
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
        statusGeneration += 1
        var env = environment
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
                guard self?.processes[tunnelID] === proc else { return }
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
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown, !stoppingPorts.contains(socksPort) else { return }
        guard socksProcess == nil else { return }
        statusGeneration += 1
        let task = Process()
        task.launchPath = "/usr/bin/env"
        let args: [String] = ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-D", socksBind, socksHost]
        task.arguments = args
        var env = environment
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
                guard self?.socksProcess === p else { return }
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
        dispatchPrecondition(condition: .onQueue(.main))
        stopListeners(on: [socksPort], owned: [socksProcess].compactMap { $0 })
        isSocksActive = false
        systemQueue.async { self.disableLocalSocksProxy() }
    }

    // MARK: - System-level helpers

    static func runCommand(_ path: String, _ args: [String]) -> (String, Int32) {
        let proc = Process()
        proc.launchPath = path
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        // Callers consume stdout only. Never leave an unread stderr pipe.
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return ("", -1) }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        let str = String(data: data, encoding: .utf8) ?? ""
        return (str, proc.terminationStatus)
    }

    func pidsListening(onLocalPort port: Int) -> Set<Int32> {
        guard (1...65535).contains(port) else { return [] }
        let (out, status) = Self.runCommand(lsofExecutable,
                                      ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        guard status == 0 else { return [] }
        return Self.parseSSHListenerPIDs(out)
    }

    static func parseSSHListenerPIDs(_ output: String) -> Set<Int32> {
        var pids = Set<Int32>()
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.first == "p" {
                pid = Int32(line.dropFirst())
            } else if line.first == "c" {
                if line.dropFirst() == "ssh", let current = pid, current > 0 {
                    pids.insert(current)
                }
                pid = nil
            }
        }
        return pids
    }

    private func sendSignal(_ signal: String, to pid: Int32) {
        _ = Self.runCommand("/bin/kill", ["-\(signal)", String(pid)])
    }

    private func terminateOwnedProcesses(_ tasks: [Process]) {
        let launched = tasks.filter { $0.processIdentifier > 0 }
        for task in launched where task.isRunning { task.terminate() }
        let deadline = Date().addingTimeInterval(0.8)
        while launched.contains(where: { $0.isRunning }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        for task in launched where task.isRunning { sendSignal("KILL", to: task.processIdentifier) }
        for task in launched { task.waitUntilExit() }
    }

    private func stopListeners(on requestedPorts: [Int], owned: [Process]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let ports = Set(requestedPorts).subtracting(stoppingPorts)
        guard !ports.isEmpty else { return }
        statusGeneration += 1
        stoppingPorts.formUnion(ports)
        // Capture identities now. Never discover new kill targets after Stop.
        let observed = ports.reduce(into: Set<Int32>()) { $0.formUnion(listenerPIDs[$1] ?? []) }
        let ownedPIDs = Set(owned.map(\.processIdentifier))
        systemQueue.async {
            self.terminateOwnedProcesses(owned)
            let external = observed.subtracting(ownedPIDs)
            for port in ports {
                let confirmed = self.pidsListening(onLocalPort: port).intersection(external)
                for pid in confirmed { self.sendSignal("TERM", to: pid) }
            }
            DispatchQueue.main.async {
                self.stoppingPorts.subtract(ports)
                self.refreshStatusFromSystem()
            }
        }
    }

    // New: refresh tunnels active state and per-port listeners from system
    func refreshStatusFromSystem() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown, !statusRefreshInFlight else { return }
        statusRefreshInFlight = true
        let generation = statusGeneration
        let snapshot = tunnels
        systemQueue.async { [weak self] in
            guard let self = self else { return }
            var statusByID: [UUID: Bool] = [:]
            var newPortCache: [Int: Bool] = [:]
            // Build set of all ports we care about
            var newListenerPIDs: [Int: Set<Int32>] = [:]
            var allPorts = Set<Int>()
            for t in snapshot { allPorts.formUnion(t.localPorts) }
            allPorts.insert(self.socksPort)
            for p in allPorts {
                let pids = self.pidsListening(onLocalPort: p)
                newListenerPIDs[p] = pids
                let listening = !pids.isEmpty
                newPortCache[p] = listening
            }
            // Derive tunnel active from per-port cache
            for t in snapshot {
                let allListening = t.localPorts.allSatisfy { newPortCache[$0] == true }
                statusByID[t.id] = allListening
            }
            let socksActive = (newPortCache[self.socksPort] == true)
            DispatchQueue.main.async {
                self.statusRefreshInFlight = false
                guard !self.isShuttingDown, generation == self.statusGeneration else { return }
                self.listenerPIDs = newListenerPIDs
                self.portListeningCache = newPortCache
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.isShuttingDown else { return }

            if let p = self.spaasProcess {
                if p.isRunning {
                    self.appendInMemory(level: .info, "spaas login requested but already running")
                    return
                } else {
                    self.spaasProcess = nil
                }
            }

            let task = Process()
            var usedShellFallback = false
            if let exe = self.resolveSpaasURL() {
                // Run resolved executable directly
                task.launchPath = exe.path
                task.arguments = ["login"]
            } else if let custom = self.spaasCustomURL {
                // fallback to custom path through bash if not executable
                if FileManager.default.isExecutableFile(atPath: custom.path) {
                    task.launchPath = custom.path
                    task.arguments = ["login"]
                } else {
                    task.launchPath = "/bin/bash"
                    task.arguments = [custom.path, "login"]
                    usedShellFallback = true
                }
            } else {
                // Final fallback to env-resolved spaas using expanded PATH
                task.launchPath = "/usr/bin/env"
                task.arguments = ["spaas", "login"]
            }

            var env = self.environment
            env["PATH"] = self.defaultPATH()
            if let custom = self.spaasCustomURL {
                let dir = URL(fileURLWithPath: custom.path).deletingLastPathComponent().path
                env["PATH"] = dir + ":" + (env["PATH"] ?? "")
            }
            task.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            self.spaasState = .running
            self.spaasLastRunAt = Date()
            self.spaasProcess = task

            let preview = (task.arguments ?? []).joined(separator: " ")
            if let lp = task.launchPath { self.writeLog("Launching: \(lp) \(preview)") }
            if usedShellFallback { self.appendInMemory(level: .stderr, "Custom spaas not executable; using bash fallback to run it") }
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
                    guard self.spaasProcess === proc else { return }
                    self.spaasLastExitStatus = Int(status)
                    self.spaasProcess = nil
                    self.spaasState = (status == 0) ? .success : .failure
                    // Re-evaluate availability in case PATH/custom changed
                    self.spaasAvailable = (self.resolveSpaasURL() != nil)
                }
            }

            do {
                try task.run()
            } catch {
                let msg = "Failed to launch spaas login: \(error.localizedDescription)"
                self.writeLog(msg)
                self.appendInMemory(level: .error, msg)
                self.spaasLastExitStatus = -1
                self.spaasProcess = nil
                self.spaasState = .failure
            }
        }
    }

    // MARK: - Shortcuts: load aliases from ~/.zshrc and run them
    func loadShortcuts() {
        dispatchPrecondition(condition: .onQueue(.main))
        systemQueue.async { [weak self] in
            guard let self = self else { return }
            let zshURL = self.homeDir().appendingPathComponent(".zshrc")
            var results: [Shortcut] = []
            if FileManager.default.fileExists(atPath: zshURL.path) {
                if let content = try? String(contentsOf: zshURL, encoding: .utf8) {
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

            var awsSet = Set<String>()
            var k8sSet = Set<String>()
            var envSet = Set<String>()
            var k8sContextMap: [String: String] = [:]

            for sc in results {
                let cmd = sc.command
                _ = cmd.replacingOccurrences(of: "=", with: " = ")

                if cmd.contains("spaas aws") {
                    if let sys = firstMatch(in: cmd, pattern: "--system\\s+([\\S]+)") { awsSet.insert(sanitizeToken(sys)) }
                    if let e = firstMatch(in: cmd, pattern: "--env\\s+([\\S]+)") { envSet.insert(sanitizeToken(e)) }
                } else if cmd.contains("spaas kubernetes") || cmd.contains("spaas k8s") {
                    if let sys = firstMatch(in: cmd, pattern: "-s\\s+([\\S]+)") {
                        let s = sanitizeToken(sys)
                        k8sSet.insert(s)
                        if let ctx = firstMatch(in: cmd, pattern: "-C\\s+([\\S]+)") { k8sContextMap[s] = sanitizeToken(ctx) }
                    }
                    if let e = firstMatch(in: cmd, pattern: "-A\\s+([\\S]+)") { envSet.insert(sanitizeToken(e)) }
                }
            }

            let awsList = Array(awsSet).sorted()
            let k8sList = Array(k8sSet).sorted()
            let envList = Array(envSet).sorted()

            self.writeLog("Detected aws systems: \(awsList.joined(separator: ", "))")
            self.writeLog("Detected k8s systems: \(k8sList.joined(separator: ", "))")
            self.writeLog("Detected envs: \(envList.joined(separator: ", "))")

            DispatchQueue.main.async {
                self.shortcuts = results
                for s in results { if self.shortcutStates[s.name] == nil { self.shortcutStates[s.name] = .idle } }
                self.awsSystems = awsList
                self.k8sSystems = k8sList
                self.foundEnvs = envList
                self.k8sContextBySystem = k8sContextMap
                if self.groupState["aws"] == nil { self.groupState["aws"] = .idle }
                if self.groupState["kubernetes"] == nil { self.groupState["kubernetes"] = .idle }
            }

            self.writeLog("Loaded shortcuts: \(results.count) from \(zshURL.path)")
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        if let re = try? NSRegularExpression(pattern: pattern, options: []) {
            let ns = text as NSString
            if let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges >= 2 { return ns.substring(with: m.range(at: 1)) }
            }
        }
        return nil
    }

    private func sanitizeToken(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimSet = CharacterSet(charactersIn: "\"'()")
        t = t.trimmingCharacters(in: trimSet)
        return t
    }

    func runGroup(kind: String, system: String, env: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.isShuttingDown else { return }
            let key = kind

            if let existing = self.groupProcesses[key] {
                if existing.isRunning {
                    self.appendInMemory(level: .info, "group \(key) run requested but already running")
                    return
                } else {
                    self.groupProcesses[key] = nil
                }
            }

            let task = Process()
            var args: [String] = []
            var usedShellFallback = false
            // Use same resolution as spaasLogin for consistency
            if let exe = self.resolveSpaasURL() {
                task.launchPath = exe.path
            } else if let custom = self.spaasCustomURL {
                if FileManager.default.isExecutableFile(atPath: custom.path) {
                    task.launchPath = custom.path
                } else {
                    task.launchPath = "/bin/bash"
                    args.append(custom.path)
                    usedShellFallback = true
                }
            } else {
                task.launchPath = "/usr/bin/env"
                args.append("spaas")
            }

            if key == "aws" {
                args.append(contentsOf: ["aws", "configure", "--system", system, "--env", env])
            } else {
                args.append(contentsOf: ["kubernetes", "configure", "-s", system])
                if let ctx = self.k8sContextBySystem[system] { args.append(contentsOf: ["-C", ctx]) }
                args.append(contentsOf: ["-A", env])
            }
            task.arguments = args

            var envVars = self.environment
            envVars["PATH"] = self.defaultPATH()
            if let custom = self.spaasCustomURL {
                let dir = URL(fileURLWithPath: custom.path).deletingLastPathComponent().path
                envVars["PATH"] = dir + ":" + (envVars["PATH"] ?? "")
            }
            task.environment = envVars

            let out = Pipe(); let err = Pipe()
            task.standardOutput = out; task.standardError = err

            self.groupState[key] = .running
            self.groupLastRunAt[key] = Date()

            let preview = (task.arguments ?? []).joined(separator: " ")
            if let lp = task.launchPath { self.writeLog("Launching group: \(lp) \(preview)") }
            if usedShellFallback { self.appendInMemory(level: .stderr, "Custom spaas not executable; using bash fallback to run group \(key)") }
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
                    guard self.groupProcesses[key] === p else { return }
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
                self.groupLastExit[key] = -1
                self.groupProcesses[key] = nil
                self.groupState[key] = .failure
            }
        }
    }

    // MARK: - Public stop APIs (non-blocking)

    func stopTunnel(for tunnelID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let idx = tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        let ports = tunnels[idx].localPorts
        tunnels[idx].isActive = false
        stopListeners(on: ports, owned: [processes[tunnelID]].compactMap { $0 })
    }

    func stopAllTunnels() {
        dispatchPrecondition(condition: .onQueue(.main))
        let procs = Array(processes.values)
        let allPorts = Array(Set(tunnels.flatMap { $0.localPorts }))
        for i in tunnels.indices { tunnels[i].isActive = false }
        stopListeners(on: allPorts, owned: procs)
    }

    // Expose port status for UI (remote feature)
    func portStatus(for port: Int) -> PortStatus {
        if let s = portListeningCache[port] { return s ? .listening : .notListening }
        return .unknown
    }

    // MARK: - Paths for config
    private func homeDir() -> URL { homeDirectory }
    private func configDir() -> URL { homeDir().appendingPathComponent("ProxyMb", isDirectory: true) }
    private func homeConfigURL() -> URL { configDir().appendingPathComponent("config.json") }

    // MARK: - Config loading

    @Published var lastConfigURL: URL? = nil

    struct ExternalConfigItem: Codable {
        let endpoint: String
        let port: Int
        let alias: String
        let sshHost: String?
    }

    private func makeTunnels(from items: [ExternalConfigItem]) -> [TunnelConfig] {
        items.map { it in
            TunnelConfig(
                name: it.alias,
                localPorts: [ it.port ],
                remoteTargets: [ it.endpoint ],
                sshHost: it.sshHost ?? "tunnel",
                isActive: false
            )
        }
    }

    enum ConfigError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    func decodeConfigItems(from data: Data) throws -> [ExternalConfigItem] {
        let items = try JSONDecoder().decode([ExternalConfigItem].self, from: data)
        var ports = Set<Int>()
        for (index, item) in items.enumerated() {
            let label = "Config item \(index + 1)"
            guard (1...65535).contains(item.port), item.port != socksPort else {
                throw ConfigError.invalid("\(label): local port must be 1–65535 and cannot use SOCKS port 1080")
            }
            guard ports.insert(item.port).inserted else {
                throw ConfigError.invalid("\(label): duplicate local port \(item.port)")
            }
            guard !item.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.invalid("\(label): alias is required")
            }
            let host = item.sshHost ?? "tunnel"
            guard !host.isEmpty, !host.hasPrefix("-"),
                  host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw ConfigError.invalid("\(label): invalid SSH host")
            }
            let endpoint = item.endpoint
            guard let separator = endpoint.lastIndex(of: ":"),
                  let remotePort = Int(endpoint[endpoint.index(after: separator)...]),
                  (1...65535).contains(remotePort) else {
                throw ConfigError.invalid("\(label): endpoint must contain a host and port (1–65535)")
            }
            let remoteHost = String(endpoint[..<separator])
            let bracketed = remoteHost.hasPrefix("[") && remoteHost.hasSuffix("]") && remoteHost.count > 2
            guard !remoteHost.isEmpty,
                  remoteHost.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  !remoteHost.contains("/"),
                  (!remoteHost.contains(":") || bracketed),
                  ((!remoteHost.contains("[") && !remoteHost.contains("]")) ||
                    (bracketed && !remoteHost.dropFirst().dropLast().contains(where: { $0 == "[" || $0 == "]" }))) else {
                throw ConfigError.invalid("\(label): invalid endpoint host; enclose IPv6 addresses in brackets")
            }
        }
        return items
    }

    func loadConfig(from url: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown else { return }
        systemQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try Data(contentsOf: url)
                let items = try self.decodeConfigItems(from: data)
                let newTunnels = self.makeTunnels(from: items)

                let homeURL = self.homeConfigURL()
                if url.standardizedFileURL.path != homeURL.standardizedFileURL.path {
                    if !FileManager.default.fileExists(atPath: self.configDir().path) {
                        try FileManager.default.createDirectory(at: self.configDir(), withIntermediateDirectories: true)
                    }
                    do {
                        try data.write(to: homeURL, options: .atomic)
                        self.writeLog("Saved uploaded config to \(homeURL.path)")
                    } catch {
                        self.writeLog("Failed to save uploaded config to \(homeURL.path): \(error.localizedDescription)")
                        throw error
                    }
                }

                self.writeLog("Loaded config from: \(url.path) (items=\(items.count))")
                self.appendInMemory(level: .info, "Loaded config: \(items.count) items")
                DispatchQueue.main.async {
                    guard !self.isShuttingDown else { return }
                    self.stopAllTunnels()
                    self.statusGeneration += 1
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

    func loadDefaultConfigIfPresent() {
        dispatchPrecondition(condition: .onQueue(.main))
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
                // Also refresh spaas availability on cold start
                self.spaasAvailable = (self.resolveSpaasURL() != nil)
            }
        }
    }

    private func listNetworkServices() -> [String] {
        let tool = networkSetupExecutable
        guard FileManager.default.isExecutableFile(atPath: tool) else { return [] }
        let (out, code) = Self.runCommand(tool, ["-listallnetworkservices"])
        guard code == 0 else { return [] }
        var result: [String] = []
        for (idx, raw) in out.split(separator: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if idx == 0 && line.lowercased().contains("asterisk") { continue }
            if line.isEmpty { continue }
            if line.hasPrefix("*") { continue }
            result.append(line)
        }
        return result
    }

    private func disableLocalSocksProxy() {
        let tool = networkSetupExecutable
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        for service in listNetworkServices() {
            let (settings, status) = Self.runCommand(tool, ["-getsocksfirewallproxy", service])
            guard status == 0 else { continue }
            let fields = settings.split(separator: "\n").reduce(into: [String: String]()) { result, line in
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
            guard fields["Port"] == String(socksPort),
                  ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(fields["Server"] ?? "") else { continue }
            _ = Self.runCommand(tool, ["-setsocksfirewallproxystate", service, "off"])
        }
    }

    // The app waits for completion instead of starting a refresh during Quit.
    func cleanupSystemProxyOnExit(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown else { return }
        isShuttingDown = true
        statusGeneration += 1
        writeLog("App exiting - performing proxy/tunnel cleanup")
        stopStatusMonitor()
        stopLogFlushTimer()
        stopSocks()
        stopAllTunnels()
        let commands = Array(groupProcesses.values) + [spaasProcess].compactMap { $0 }
        spaasProcess = nil
        groupProcesses.removeAll()
        systemQueue.async {
            self.terminateOwnedProcesses(commands)
            self.writeLog("Cleanup complete")
            DispatchQueue.main.async(execute: completion)
        }
    }
}
