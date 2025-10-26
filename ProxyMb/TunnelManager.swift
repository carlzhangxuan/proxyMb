import Foundation
import Combine

class TunnelManager: ObservableObject {
    @Published var tunnels: [TunnelConfig] = TunnelConfig.presets

    private var processes: [UUID: Process] = [:]

    init() {
        // Detect system state on launch so indicators reflect reality
        refreshStatusFromSystem()
    }

    func startTunnel(for tunnelID: UUID) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnelID }) else { return }
        let config = tunnels[index]
        guard processes[tunnelID] == nil else { return }

        let task = Process()
        task.launchPath = "/usr/bin/ssh"

        var args: [String] = ["-N", "-o", "ExitOnForwardFailure=yes"]
        for (lp, target) in zip(config.localPorts, config.remoteTargets) {
            args.append(contentsOf: ["-L", "\(lp):\(target)"])
        }
        args.append(config.sshHost)
        task.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        task.terminationHandler = { [weak self] _ in
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
        } catch {
            // Optionally handle error
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
