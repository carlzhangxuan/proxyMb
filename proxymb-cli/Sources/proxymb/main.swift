import Foundation
import Darwin

@discardableResult
func run(_ cmd: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    p.standardOutput = FileHandle.standardOutput
    p.standardError  = FileHandle.standardError
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch {
        fputs("Error running \(cmd): \(error)\n", stderr)
        return -1
    }
}

func which(_ name: String) -> String? {
    let fm = FileManager.default
    let candidates = ["/usr/bin/\(name)", "/bin/\(name)", "/usr/sbin/\(name)", "/usr/local/bin/\(name)"]
    for c in candidates { if fm.isExecutableFile(atPath: c) { return c } }
    return nil
}

func isPortOpen(_ port: Int, timeout: Int = 1) -> Bool {
    guard let nc = which("nc") else { return false }
    let s1 = run(nc, ["-z", "-G", String(timeout), "127.0.0.1", String(port)])
    if s1 == 0 { return true }
    let s2 = run(nc, ["-z", "-G", String(timeout), "::1", String(port)])
    return s2 == 0
}

func sshArgs(host: String, forwards: [(Int, String)]) -> [String] {
    var args = ["-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes"]
    for (lp, target) in forwards {
        args.append(contentsOf: ["-L", "\(lp):\(target)"])
    }
    args.append(host)
    return args
}

func usage(_ code: Int32 = 0) -> Never {
    let text = """
    proxymb - minimal SSH tunnel helper (CLI)

    Usage:
      proxymb tunnel --ssh-host <host> -L <lport>:<rhost>:<rport> [-L ...]
      proxymb probe <port>
      proxymb kill-listeners <port> [<port> ...]
      proxymb version
      proxymb help

    Examples:
      proxymb tunnel --ssh-host localhost -L 9280:localhost:8001 -L 40443:localhost:8002
      proxymb probe 9280
      proxymb kill-listeners 9280 40443
    """
    print(text)
    exit(code)
}

// MARK: - Arg parsing

var it = CommandLine.arguments.dropFirst().makeIterator()
func nextArg() -> String? { it.next() }

guard let cmd = nextArg() else { usage(1) }

switch cmd {
case "help", "-h", "--help":
    usage(0)

case "version", "--version", "-v":
    print("proxymb 0.1.0")

case "probe":
    guard let p = nextArg(), let port = Int(p) else { fputs("probe needs a <port>\n", stderr); usage(2) }
    let open = isPortOpen(port)
    print(open ? "open" : "closed")
    exit(open ? 0 : 1)

case "kill-listeners":
    var ports: [Int] = []
    while let a = nextArg() { if let v = Int(a) { ports.append(v) } }
    if ports.isEmpty { fputs("kill-listeners needs at least one <port>\n", stderr); usage(2) }
    guard let lsof = which("lsof") else { fputs("lsof not found\n", stderr); exit(3) }
    var killed = 0
    for port in ports {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: lsof)
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t", "-c", "ssh"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        do {
            try task.run(); task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let pids = String(data: data, encoding: .utf8)?.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { pid_t($0) } ?? []
            for pid in pids { _ = kill(pid, SIGTERM); usleep(200_000); if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } ; killed += 1 }
        } catch {
            fputs("lsof failed for port \(port): \(error)\n", stderr)
        }
    }
    print("killed: \(killed)")

case "tunnel":
    var host: String?
    var forwards: [(Int, String)] = []
    while let a = nextArg() {
        if a == "--ssh-host" { host = nextArg() }
        else if a == "-L" {
            guard let spec = nextArg() else { fputs("-L needs <lport>:<rhost>:<rport>\n", stderr); exit(2) }
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let lp = Int(parts[0]) else {
                fputs("invalid -L spec: \(spec)\n", stderr); exit(2)
            }
            forwards.append((lp, "\(parts[1]):\(parts[2])"))
        } else if a == "--" { break }
        else if a.hasPrefix("-") { fputs("unknown option: \(a)\n", stderr); usage(2) }
        else { fputs("unexpected arg: \(a)\n", stderr); usage(2) }
    }
    guard let host = host, !forwards.isEmpty else { fputs("tunnel requires --ssh-host and at least one -L\n", stderr); usage(2) }
    guard let ssh = which("ssh") else { fputs("ssh not found\n", stderr); exit(3) }
    let args = sshArgs(host: host, forwards: forwards)
    print("exec: \(ssh) \(args.joined(separator: " "))")
    exit(run(ssh, args))

default:
    fputs("Unknown command: \(cmd)\n", stderr)
    usage(2)
}
