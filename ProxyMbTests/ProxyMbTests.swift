import XCTest
#if SWIFT_PACKAGE
@testable import ProxyMbCore
#else
@testable import ProxyMb
#endif

final class ProxyMbTests: XCTestCase {
    private var temporaryHome: URL!

    override func setUpWithError() throws {
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyMbTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Each test owns this unique directory; never remove the user's home.
        try FileManager.default.removeItem(at: temporaryHome)
    }

    @MainActor
    private func manager(environment: [String: String] = [:],
                         lsofExecutable: String = "/usr/bin/false") -> TunnelManager {
        TunnelManager(startRuntime: false, homeDirectory: temporaryHome, environment: environment,
                      networkSetupExecutable: "/usr/bin/false", lsofExecutable: lsofExecutable)
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var realProjectFiles: [URL] {
        ["ProxyMb/ContentView.swift", "ProxyMb/PortStatus.swift", "ProxyMb/ProxyMbApp.swift",
         "ProxyMb/SSHViewModel.swift", "ProxyMb/TunnelConfig.swift", "ProxyMb/TunnelManager.swift",
         "ProxyMbTests/ProxyMbTests.swift", "ProxyMbUITests/ProxyMbUITests.swift",
         "ProxyMbUITests/ProxyMbUITestsLaunchTests.swift", "README.md",
         "ProxyMb.xcodeproj/project.pbxproj", ".github/workflows/ci.yml",
         ".github/workflows/release.yml", "scripts/build_and_package.sh"].map {
            repository.appendingPathComponent($0)
        }
    }

    @MainActor
    private func drain(_ manager: TunnelManager) async {
        await withCheckedContinuation { continuation in
            manager.systemQueue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for process state")
    }

    @MainActor
    func testProductionShortcutsReloadWithoutStoppingProcesses() async throws {
        // These are the seven systems from the actual shell configuration.
        let systems = ["content-ml", "sn-location", "vertical-ml", "news-delivery",
                       "sn-feed", "ml-serving", "ml-training"]
        let aliases = systems.flatMap { system in
            [
                "alias aws-\(system)='eval \"$(spaas aws configure --system \(system) --env prd)\"'",
                "alias k8s-\(system)='eval \"$(spaas kubernetes configure -s \(system) -C common-0 -A prd)\"'"
            ]
        }
        let shellConfig = temporaryHome.appendingPathComponent(".zshrc")
        try Data(aliases.prefix(4).joined(separator: "\n").utf8).write(to: shellConfig)
        let manager = try fakeSSHManager()
        manager.startSocks()
        let process = try XCTUnwrap(manager.socksProcess)
        defer { manager.stopSocks() }
        manager.loadShortcuts()
        XCTAssertTrue(manager.isLoadingShortcuts)
        await drain(manager)
        XCTAssertEqual(manager.awsSystems, ["content-ml", "sn-location"])

        try Data(aliases.joined(separator: "\n").utf8).write(to: shellConfig)
        manager.loadShortcuts()
        manager.loadShortcuts() // Repeated requests while loading are coalesced.
        await drain(manager)
        XCTAssertFalse(manager.isLoadingShortcuts)
        XCTAssertNil(manager.shortcutLoadError)
        XCTAssertEqual(manager.awsSystems, systems.sorted())
        XCTAssertEqual(manager.k8sSystems, systems.sorted())
        XCTAssertEqual(manager.foundEnvs, ["prd"])
        XCTAssertEqual(manager.shortcuts.count, 14)
        for system in systems {
            XCTAssertEqual(manager.k8sContextBySystem[system], "common-0")
        }
        XCTAssertEqual(manager.shortcutSourcePath, shellConfig.path)
        XCTAssertTrue(manager.socksProcess === process)
        XCTAssertTrue(process.isRunning, "Reading aliases must not stop SOCKS or execute spaas")
        manager.stopSocks()
        await drain(manager)
    }

    @MainActor
    func testShortcutReadErrorsPreserveChoicesAndRecover() async throws {
        let manager = manager()
        let shellConfig = temporaryHome.appendingPathComponent(".zshrc")
        manager.loadShortcuts()
        await drain(manager)
        XCTAssertNotNil(manager.shortcutLoadError, "Missing files must not fail silently")
        XCTAssertFalse(manager.isLoadingShortcuts)

        let alias = "alias content-aws-prd='eval \"$(spaas aws configure --system content-ml --env prd)\"'"
        try Data(alias.utf8).write(to: shellConfig)
        manager.loadShortcuts()
        await drain(manager)
        XCTAssertNil(manager.shortcutLoadError)
        XCTAssertEqual(manager.awsSystems, ["content-ml"])

        try Data([0xFF, 0xFE, 0xFF]).write(to: shellConfig)
        manager.loadShortcuts()
        await drain(manager)
        XCTAssertNotNil(manager.shortcutLoadError, "Invalid UTF-8 must be reported")
        XCTAssertFalse(manager.isLoadingShortcuts)
        XCTAssertEqual(manager.awsSystems, ["content-ml"], "Read failures must keep working choices")

        try Data().write(to: shellConfig)
        manager.loadShortcuts()
        await drain(manager)
        XCTAssertNil(manager.shortcutLoadError)
        XCTAssertTrue(manager.awsSystems.isEmpty, "A successfully read empty file clears old aliases")
        XCTAssertTrue(manager.shortcuts.isEmpty)
    }

    @MainActor
    func testShortcutPartialAndCommentedLinesDoNotCreateChoices() async throws {
        let content = """
        # alias disabled='$(spaas aws configure --system ignored --env prd)'
        alias incomplete=
        alias unfinished='$(spaas kubernetes configure -s ignored
        alias unrelated='echo hello'
        alias content-aws-prd='$(spaas aws configure --system content-ml --env prd)'
        alias content-k8s-prd='$(spaas kubernetes configure -s content-ml -C common-0 -A prd)'
        """
        try Data(content.utf8).write(to: temporaryHome.appendingPathComponent(".zshrc"))
        let manager = manager()
        manager.loadShortcuts()
        await drain(manager)
        XCTAssertNil(manager.shortcutLoadError)
        XCTAssertEqual(manager.awsSystems, ["content-ml"])
        XCTAssertEqual(manager.k8sSystems, ["content-ml"])
        XCTAssertEqual(manager.foundEnvs, ["prd"])
        XCTAssertEqual(manager.shortcuts.count, 3)
    }

    @MainActor
    func testInstalledShellShortcutsReadOnly() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROXYMB_ZSHRC_FIXTURE"] else {
            throw XCTSkip("Set PROXYMB_ZSHRC_FIXTURE for the read-only installed shell configuration check")
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path),
                                        to: temporaryHome.appendingPathComponent(".zshrc"))
        let manager = manager()
        manager.loadShortcuts()
        await drain(manager)
        let expected = ["content-ml", "ml-serving", "ml-training", "news-delivery",
                        "sn-feed", "sn-location", "vertical-ml"]
        XCTAssertEqual(manager.awsSystems, expected)
        XCTAssertEqual(manager.k8sSystems, expected)
        XCTAssertEqual(manager.foundEnvs, ["dev", "prd"])
        for system in expected {
            XCTAssertEqual(manager.k8sContextBySystem[system], "common-0")
        }
    }

    @MainActor
    func testLargeStdoutAndStderrUsingRealProjectFiles() async throws {
        let files = Array(repeating: realProjectFiles, count: 10).flatMap { $0 }
        let expected = try files.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }
        XCTAssertGreaterThan(expected.count, 1_000_000)
        let complete = expectation(description: "Both pipes drain without deadlock")
        DispatchQueue.global().async {
            let stdout = TunnelManager.runCommand("/bin/cat", files.map(\.path))
            XCTAssertEqual(stdout.1, 0)
            XCTAssertEqual(Data(stdout.0.utf8), expected)
            let stderr = TunnelManager.runCommand("/bin/sh",
                ["-c", "cat \"$@\" >&2; printf drained", "probe"] + files.map(\.path))
            XCTAssertEqual(stderr.1, 0)
            XCTAssertEqual(stderr.0, "drained")
            complete.fulfill()
        }
        await fulfillment(of: [complete], timeout: 15)
    }

    @MainActor
    func testCommandFailureIsReported() async {
        XCTAssertEqual(TunnelManager.runCommand("/nonexistent/proxymb-test-command", []).1, -1)
        XCTAssertEqual(TunnelManager.runCommand("/bin/sh", ["-c", "exit 7"]).1, 7)
    }

    func testOnlyExactSSHListenerRecordsAreAccepted() {
        XCTAssertEqual(TunnelManager.parseSSHListenerPIDs("p12\ncssh\nf3\np13\ncsshd\np14\ncssh-helper\n"), [12])
        XCTAssertEqual(TunnelManager.parseSSHListenerPIDs("p11\np20\ncssh\n"), [20])
        XCTAssertEqual(TunnelManager.parseSSHListenerPIDs("pbad\ncssh\np-1\ncssh\np0\ncssh\n"), [])
        XCTAssertEqual(TunnelManager.parseSSHListenerPIDs("cssh\np30\n"), [])
        XCTAssertEqual(TunnelManager.parseSSHListenerPIDs("102 /usr/bin/ssh -D 10800 tunnel"), [])
        XCTAssertEqual(TunnelManager.parseSSHListenerPIDs("103 /usr/bin/ssh -D 0.0.0.0:1080 tunnel"), [])
    }

    @MainActor
    func testListenerProbeSelectsExactPortAndRequiresSuccessfulLookup() async throws {
        let tool = temporaryHome.appendingPathComponent("lsof")
        let script = """
        #!/bin/sh
        case " $* " in
          *" -iTCP:1080 "*) printf 'p42\\ncssh\\n' ;;
          *" -iTCP:10800 "*) printf 'p43\\ncssh\\n' ;;
          *) printf 'p44\\ncssh\\n'; exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let manager = TunnelManager(startRuntime: false, homeDirectory: temporaryHome,
                                    networkSetupExecutable: "/usr/bin/false", lsofExecutable: tool.path)
        XCTAssertEqual(manager.pidsListening(onLocalPort: 1080), [42])
        XCTAssertEqual(manager.pidsListening(onLocalPort: 10800), [43])
        XCTAssertTrue(manager.pidsListening(onLocalPort: 59991).isEmpty)
        XCTAssertTrue(manager.pidsListening(onLocalPort: -1).isEmpty)
    }

    @MainActor
    func testRunningSSHCommandWithoutListenerIsNotActive() async throws {
        let manager = try fakeSSHManager()
        let tunnel = TunnelConfig(name: "No listener", localPorts: [59991],
                                  remoteTargets: ["localhost:443"], sshHost: "unused")
        manager.tunnels = [tunnel]
        manager.startTunnel(for: tunnel.id)
        let task = try XCTUnwrap(manager.processes[tunnel.id])
        XCTAssertTrue(task.isRunning)
        XCTAssertFalse(manager.tunnels[0].isActive, "A launched process is not proof of a listening port")
        XCTAssertEqual(manager.tunnelStatus(for: tunnel), .checking)
        XCTAssertEqual(manager.portStatus(for: 59991), .checking)
        XCTAssertTrue(manager.canStopTunnel(tunnel), "A connecting process must remain stoppable")
        await drain(manager)
        XCTAssertFalse(manager.tunnels[0].isActive)
        XCTAssertEqual(manager.portStatus(for: 59991), .notListening)
        XCTAssertTrue(manager.canStopTunnel(tunnel))
        XCTAssertTrue(manager.pidsListening(onLocalPort: 59991).isEmpty)
        manager.stopAllTunnels()
        await drain(manager)
        XCTAssertFalse(task.isRunning)
    }

    @MainActor
    func testSocksLaunchWithoutListenerIsNotActive() async throws {
        let manager = try fakeSSHManager()
        manager.startSocks()
        let task = try XCTUnwrap(manager.socksProcess)
        XCTAssertTrue(task.isRunning)
        XCTAssertFalse(manager.isSocksActive, "SOCKS must not turn green before a listener is detected")
        XCTAssertEqual(manager.socksStatus, .checking)
        XCTAssertTrue(manager.canStopSocks)
        await drain(manager)
        XCTAssertFalse(manager.isSocksActive)
        XCTAssertEqual(manager.socksStatus, .checking)
        XCTAssertTrue(manager.canStopSocks)
        manager.stopSocks()
        await drain(manager)
        XCTAssertFalse(task.isRunning)
        try await waitUntil { manager.socksProcess == nil }
        XCTAssertFalse(manager.canStopSocks)
    }

    private func listenerFixture() throws -> URL {
        let tool = temporaryHome.appendingPathComponent("lsof-fixture")
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            -iTCP:*) port="${arg#-iTCP:}" ;;
          esac
        done
        fixture_dir="$(dirname "$0")"
        printf '%s\\n' "$port" >> "$fixture_dir/probe-trace"
        record="$fixture_dir/listener-$port"
        if [ -f "$record" ]; then
          /bin/cat "$record"
          if [ -f "$fixture_dir/consume-$port" ]; then /bin/rm "$record"; fi
          exit 0
        else
          exit 1
        fi
        """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    @MainActor
    func testUnavailableMonitorDoesNotClaimAConnectionState() async {
        let manager = manager(lsofExecutable: "/nonexistent/proxymb-lsof")
        let tunnel = TunnelConfig(name: "Unavailable probe", localPorts: [15432],
                                  remoteTargets: ["db.internal:5432"], sshHost: "tunnel")
        manager.tunnels = [tunnel]
        manager.refreshStatusFromSystem()
        await drain(manager)
        XCTAssertEqual(manager.portStatus(for: 15432), .unknown)
        XCTAssertEqual(manager.tunnelStatus(for: tunnel), .unknown)
        XCTAssertEqual(manager.socksStatus, .unknown)
        XCTAssertFalse(manager.tunnels[0].isActive)
        XCTAssertFalse(manager.isSocksActive)
    }

    @MainActor
    func testMonitorUpdatesEachPortAndAllowsStoppingPartialTunnel() async throws {
        let tool = try listenerFixture()
        let manager = manager(lsofExecutable: tool.path)
        let tunnel = TunnelConfig(name: "Partial forwarding", localPorts: [15432, 16379],
                                  remoteTargets: ["db.internal:5432", "cache.internal:6379"], sshHost: "tunnel")
        manager.tunnels = [tunnel]
        XCTAssertEqual(manager.tunnelStatus(for: tunnel), .unknown)
        XCTAssertEqual(manager.socksStatus, .unknown)
        XCTAssertFalse(manager.canStopTunnel(tunnel))
        for port in [15432, 16379, 1080] {
            try Data("p424242\ncssh\n".utf8)
                .write(to: temporaryHome.appendingPathComponent("listener-\(port)"))
        }
        manager.refreshStatusFromSystem()
        await drain(manager)
        XCTAssertTrue(manager.tunnels[0].isActive)
        XCTAssertTrue(manager.isSocksActive)
        XCTAssertEqual(manager.tunnelStatus(for: tunnel), .listening)
        XCTAssertEqual(manager.socksStatus, .listening)
        XCTAssertTrue(manager.canStopSocks)

        try FileManager.default.removeItem(at: temporaryHome.appendingPathComponent("listener-16379"))
        try FileManager.default.removeItem(at: temporaryHome.appendingPathComponent("listener-1080"))
        manager.refreshStatusFromSystem()
        await drain(manager)
        XCTAssertFalse(manager.tunnels[0].isActive)
        XCTAssertFalse(manager.isSocksActive)
        XCTAssertEqual(manager.portStatus(for: 15432), .listening)
        XCTAssertEqual(manager.portStatus(for: 16379), .notListening)
        XCTAssertEqual(manager.tunnelStatus(for: tunnel), .notListening)
        XCTAssertTrue(manager.canStopTunnel(tunnel), "A partially listening tunnel still needs a Stop button")
        XCTAssertEqual(manager.socksStatus, .notListening)
        XCTAssertFalse(manager.canStopSocks)

        // A non-SSH listener must not turn the tunnel green.
        try Data("p424242\ncpython3\n".utf8)
            .write(to: temporaryHome.appendingPathComponent("listener-15432"))
        manager.refreshStatusFromSystem()
        await drain(manager)
        XCTAssertEqual(manager.portStatus(for: 15432), .notListening)
        XCTAssertFalse(manager.canStopTunnel(tunnel))
        XCTAssertTrue(PortStatus.listening.description.contains("remote service health is not checked"))
    }

    @MainActor
    func testPeriodicMonitorDetectsListenersAppearingAndDisappearing() async throws {
        let tool = try listenerFixture()
        let configDirectory = temporaryHome.appendingPathComponent("ProxyMb")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try config().write(to: configDirectory.appendingPathComponent("config.json"))
        try Data().write(to: temporaryHome.appendingPathComponent(".zshrc"))
        let manager = TunnelManager(startRuntime: true, homeDirectory: temporaryHome,
                                    networkSetupExecutable: "/usr/bin/false", lsofExecutable: tool.path)
        try await waitUntil { manager.tunnels.count == 1 && manager.portStatus(for: 15432) == .notListening }
        for port in [15432, 1080] {
            try Data("p424242\ncssh\n".utf8)
                .write(to: temporaryHome.appendingPathComponent("listener-\(port)"))
        }
        // No manual refresh: the actual repeating timer must update both lights.
        try await waitUntil { manager.tunnels[0].isActive && manager.isSocksActive }
        for port in [15432, 1080] {
            try FileManager.default.removeItem(at: temporaryHome.appendingPathComponent("listener-\(port)"))
        }
        try await waitUntil { !manager.tunnels[0].isActive && !manager.isSocksActive }
        XCTAssertEqual(manager.portStatus(for: 15432), .notListening)
        let complete = expectation(description: "Stop the monitor after the simulated listeners are gone")
        manager.cleanupSystemProxyOnExit { complete.fulfill() }
        await fulfillment(of: [complete], timeout: 5)
    }

    @MainActor
    func testMonitorRejectsSnapshotQueuedBeforeTunnelExitAndRetries() async throws {
        let tool = try listenerFixture()
        let manager = try fakeSSHManager(lsofExecutable: tool.path)
        let tunnel = TunnelConfig(name: "Exit race", localPorts: [59991],
                                  remoteTargets: ["localhost:443"], sshHost: "unused")
        manager.tunnels = [tunnel]
        manager.startTunnel(for: tunnel.id)
        let process = try XCTUnwrap(manager.processes[tunnel.id])
        await drain(manager)
        let trace = temporaryHome.appendingPathComponent("probe-trace")
        try Data().write(to: trace)

        // Hold the worker before a snapshot; termination callbacks still run on main.
        let gate = DispatchSemaphore(value: 0)
        manager.systemQueue.async { _ = gate.wait(timeout: .now() + 5) }
        defer { gate.signal() }
        manager.refreshStatusFromSystem()
        process.terminate()
        try await waitUntil { manager.processes[tunnel.id] == nil }
        XCTAssertFalse(manager.tunnels[0].isActive)

        // The first probe returns a stale listener, then the retry sees it gone.
        try Data("p424242\ncssh\n".utf8)
            .write(to: temporaryHome.appendingPathComponent("listener-59991"))
        try Data().write(to: temporaryHome.appendingPathComponent("consume-59991"))
        gate.signal()
        await drain(manager)
        await drain(manager)
        XCTAssertFalse(manager.tunnels[0].isActive, "A pre-exit snapshot must never resurrect green")
        XCTAssertEqual(manager.portStatus(for: 59991), .notListening)
        let probes = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(probes.filter { $0 == "59991" }.count, 2, "Discarded snapshots must retry immediately")
    }

    @MainActor
    private func fakeSpaasManager() throws -> TunnelManager {
        let executable = temporaryHome.appendingPathComponent("spaas")
        let script = """
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf '%s\\n' "$@" > "$fixture_dir/arguments-$1"
        while [ ! -f "$fixture_dir/finish-$1" ]; do /bin/sleep 0.02; done
        printf 'Login completed successfully\\n'
        exit "$(/bin/cat "$fixture_dir/finish-$1")"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let manager = manager(environment: ["PATH": temporaryHome.path + ":/usr/bin:/bin"])
        XCTAssertEqual(manager.resolveSpaasURL(), executable, "Tests must never execute a real spaas binary")
        return manager
    }

    @MainActor
    func testSpaasLoginIndicatorsFollowExitStatusAndIgnoreOldCallbacks() async throws {
        let manager = try fakeSpaasManager()
        XCTAssertEqual(manager.spaasState, .idle)
        manager.spaasLogin()
        try await waitUntil { manager.spaasState == .running }
        let first = try XCTUnwrap(manager.spaasProcess)
        defer { if first.isRunning { first.terminate() } }
        let oldExit = try XCTUnwrap(first.terminationHandler)
        XCTAssertNil(manager.spaasLastExitStatus)
        let finish = temporaryHome.appendingPathComponent("finish-login")
        try Data("0".utf8).write(to: finish)
        try await waitUntil { manager.spaasState == .success }
        XCTAssertEqual(manager.spaasLastExitStatus, 0)
        XCTAssertNotNil(manager.spaasLastRunAt)

        try FileManager.default.removeItem(at: finish)
        manager.spaasLogin()
        try await waitUntil { manager.spaasState == .running }
        let second = try XCTUnwrap(manager.spaasProcess)
        defer { if second.isRunning { second.terminate() } }
        XCTAssertFalse(first === second)
        XCTAssertNil(manager.spaasLastExitStatus, "A new command must not display the previous exit code")
        oldExit(first)
        await drain(manager)
        XCTAssertTrue(manager.spaasProcess === second)
        XCTAssertEqual(manager.spaasState, .running)
        try Data("7".utf8).write(to: finish)
        try await waitUntil { manager.spaasState == .failure }
        XCTAssertEqual(manager.spaasLastExitStatus, 7, "Success-looking output is not a successful exit")
    }

    @MainActor
    func testAWSAndKubernetesIndicatorsAreScopedToSelectionAndCommand() async throws {
        let manager = try fakeSpaasManager()
        manager.k8sContextBySystem = ["content-ml": "common-0", "sn-feed": "common-0"]
        for kind in ["aws", "kubernetes"] {
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "prd"), .idle)
            manager.runGroup(kind: kind, system: "content-ml", env: "prd")
            try await waitUntil { manager.groupProcesses[kind] != nil }
            let first = try XCTUnwrap(manager.groupProcesses[kind])
            defer { if first.isRunning { first.terminate() } }
            let oldExit = try XCTUnwrap(first.terminationHandler)
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "prd"), .running)
            XCTAssertNil(manager.groupLastExit[kind])
            let finish = temporaryHome.appendingPathComponent("finish-\(kind)")
            try Data("0".utf8).write(to: finish)
            try await waitUntil { manager.groupState[kind] == .success }
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "prd"), .success)
            XCTAssertEqual(manager.groupLastExit[kind], 0)
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "sn-feed", env: "prd"), .idle)
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "dev"), .idle)
            if kind == "kubernetes" {
                manager.k8sContextBySystem["content-ml"] = "common-1"
                XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "prd"), .idle)
                manager.k8sContextBySystem["content-ml"] = "common-0"
            }

            try FileManager.default.removeItem(at: finish)
            manager.runGroup(kind: kind, system: "sn-feed", env: "prd")
            try await waitUntil { manager.groupProcesses[kind] != nil }
            let second = try XCTUnwrap(manager.groupProcesses[kind])
            defer { if second.isRunning { second.terminate() } }
            XCTAssertNil(manager.groupLastExit[kind])
            oldExit(first)
            await drain(manager)
            XCTAssertTrue(manager.groupProcesses[kind] === second)
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "sn-feed", env: "prd"), .running)
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "prd"), .idle)
            try Data("7".utf8).write(to: finish)
            try await waitUntil { manager.groupState[kind] == .failure }
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "sn-feed", env: "prd"), .failure)
            XCTAssertEqual(manager.groupLastExit[kind], 7)
            let arguments = try String(contentsOf: temporaryHome.appendingPathComponent("arguments-\(kind)"),
                                       encoding: .utf8).split(separator: "\n").map(String.init)
            let expected = kind == "aws"
                ? ["aws", "configure", "--system", "sn-feed", "--env", "prd"]
                : ["kubernetes", "configure", "-s", "sn-feed", "-C", "common-0", "-A", "prd"]
            XCTAssertEqual(arguments, expected)
        }
        XCTAssertTrue(TunnelManager.SpaasState.success.description.contains("credentials"))
        XCTAssertEqual(TunnelManager.SpaasState.idle.color, .gray)
        XCTAssertEqual(TunnelManager.SpaasState.running.color, .orange)
        XCTAssertEqual(TunnelManager.SpaasState.success.color, .green)
        XCTAssertEqual(TunnelManager.SpaasState.failure.color, .red)
    }

    @MainActor
    func testRefreshClearsAllCommandIndicatorsAndIgnoresTheirOldCallbacks() async throws {
        let manager = try fakeSpaasManager()
        manager.spaasLogin()
        manager.runGroup(kind: "aws", system: "content-ml", env: "prd")
        manager.runGroup(kind: "kubernetes", system: "content-ml", env: "prd")
        try await waitUntil { manager.spaasProcess != nil && manager.groupProcesses.count == 2 }
        let tasks = [try XCTUnwrap(manager.spaasProcess)] + Array(manager.groupProcesses.values)
        let callbacks = try tasks.map { try XCTUnwrap($0.terminationHandler) }
        manager.refreshAll()
        try await waitUntil {
            manager.spaasState == .idle && manager.groupState.values.allSatisfy { $0 == .idle }
                && tasks.allSatisfy { !$0.isRunning }
        }
        for (task, callback) in zip(tasks, callbacks) { callback(task) }
        await drain(manager)
        XCTAssertEqual(manager.spaasState, .idle)
        XCTAssertNil(manager.spaasLastExitStatus)
        for kind in ["aws", "kubernetes"] {
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "prd"), .idle)
            XCTAssertNil(manager.groupLastExit[kind])
        }
        let complete = expectation(description: "Stop the timer started by Refresh")
        manager.cleanupSystemProxyOnExit { complete.fulfill() }
        await fulfillment(of: [complete], timeout: 5)
    }

    @MainActor
    func testCommandLaunchFailuresNeverLeaveOrangeOrGreenIndicators() async throws {
        let manager = try fakeSpaasManager()
        // An executable file with an invalid binary format fails Process.run().
        try Data([0xFF, 0xFF, 0xFF]).write(to: temporaryHome.appendingPathComponent("spaas"))
        manager.spaasLogin()
        try await waitUntil { manager.spaasState == .failure }
        XCTAssertEqual(manager.spaasLastExitStatus, -1)
        XCTAssertNil(manager.spaasProcess)
        for kind in ["aws", "kubernetes"] {
            manager.runGroup(kind: kind, system: "content-ml", env: "prd")
            try await waitUntil { manager.groupState[kind] == .failure }
            XCTAssertEqual(manager.groupStatus(kind: kind, system: "content-ml", env: "prd"), .failure)
            XCTAssertEqual(manager.groupLastExit[kind], -1)
            XCTAssertNil(manager.groupProcesses[kind])
        }
    }

    @MainActor
    func testExpandedSpaasPathWithoutShellLookup() async throws {
        let executable = temporaryHome.appendingPathComponent(".local/bin/spaas")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manager = manager(environment: ["PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin"])
        // Directories with execute permission are not executable files.
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
        XCTAssertNotEqual(manager.resolveSpaasURL(), executable)
        try FileManager.default.removeItem(at: executable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertEqual(manager.resolveSpaasURL(), executable)
    }

    private func config(port: Int = 15432, endpoint: String = "db.internal:5432",
                        alias: String = "Database", sshHost: String? = nil) throws -> Data {
        var item: [String: Any] = ["port": port, "endpoint": endpoint, "alias": alias]
        if let sshHost { item["sshHost"] = sshHost }
        return try JSONSerialization.data(withJSONObject: [item])
    }

    @MainActor
    func testConfigValidationBoundariesAndIPv6() async throws {
        let manager = manager()
        XCTAssertEqual(try manager.decodeConfigItems(from: config()).count, 1)
        for port in [1, 65535] {
            XCTAssertNoThrow(try manager.decodeConfigItems(from: config(port: port)))
        }
        for port in [-1, 0, 1080, 65536, 70000] {
            XCTAssertThrowsError(try manager.decodeConfigItems(from: config(port: port)))
        }
        for endpoint in ["", ":443", "host", "host:0", "host:65536", "https://host:443", "bad host:443",
                         "::1:443", "[]:443", "[::1:443", "::1]:443", "[[::1]]:443"] {
            XCTAssertThrowsError(try manager.decodeConfigItems(from: config(endpoint: endpoint)), endpoint)
        }
        for endpoint in ["localhost:443", "db.internal:5432", "127.0.0.1:80", "[::1]:443", "[2001:db8::1]:65535"] {
            XCTAssertNoThrow(try manager.decodeConfigItems(from: config(endpoint: endpoint)), endpoint)
        }
        for sshHost in ["", "-oProxyCommand=bad", "host\nother", "host other"] {
            XCTAssertThrowsError(try manager.decodeConfigItems(from: config(sshHost: sshHost)))
        }
        XCTAssertNoThrow(try manager.decodeConfigItems(from: config(sshHost: "user@bastion")))
        XCTAssertThrowsError(try manager.decodeConfigItems(from: config(alias: " \n")))
        XCTAssertThrowsError(try manager.decodeConfigItems(from: Data("[{\"port\":15432}]".utf8)))
        XCTAssertNoThrow(try manager.decodeConfigItems(from: Data("[]".utf8)))
        let item = try XCTUnwrap((JSONSerialization.jsonObject(with: config()) as? [[String: Any]])?.first)
        let duplicate = try JSONSerialization.data(withJSONObject: [item, item])
        XCTAssertThrowsError(try manager.decodeConfigItems(from: duplicate))
    }

    @MainActor
    func testInvalidImportPreservesSavedConfigAndRunningState() async throws {
        let manager = manager()
        let saved = temporaryHome.appendingPathComponent("ProxyMb/config.json")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try config()
        try original.write(to: saved)
        let active = TunnelConfig(name: "Existing", localPorts: [15432], remoteTargets: ["db.internal:5432"],
                                  sshHost: "tunnel", isActive: true)
        manager.tunnels = [active]
        let upload = temporaryHome.appendingPathComponent("invalid.json")
        try config(port: 70000).write(to: upload)
        manager.loadConfig(from: upload)
        await drain(manager)
        XCTAssertEqual(try Data(contentsOf: saved), original)
        XCTAssertEqual(manager.tunnels.first?.id, active.id)
        XCTAssertEqual(manager.tunnels.first?.isActive, true)
        XCTAssertNil(manager.lastConfigURL)
    }

    @MainActor
    func testSaveFailureDoesNotReplaceCurrentTunnels() async throws {
        let manager = manager()
        let configDirectory = temporaryHome.appendingPathComponent("ProxyMb")
        try Data("not a directory".utf8).write(to: configDirectory)
        let active = TunnelConfig(name: "Existing", localPorts: [15432], remoteTargets: ["db.internal:5432"], sshHost: "tunnel")
        manager.tunnels = [active]
        let upload = temporaryHome.appendingPathComponent("valid.json")
        try config().write(to: upload)
        manager.loadConfig(from: upload)
        await drain(manager)
        XCTAssertEqual(manager.tunnels.first?.id, active.id)
        XCTAssertNil(manager.lastConfigURL)
    }

    @MainActor
    func testValidImportPersistsAndLoads() async throws {
        let manager = manager()
        let upload = temporaryHome.appendingPathComponent("valid.json")
        let data = try config()
        try data.write(to: upload)
        manager.loadConfig(from: upload)
        await drain(manager)
        await drain(manager)
        XCTAssertEqual(manager.tunnels.first?.name, "Database")
        XCTAssertEqual(manager.lastConfigURL, upload)
        XCTAssertEqual(try Data(contentsOf: temporaryHome.appendingPathComponent("ProxyMb/config.json")), data)
    }

    @MainActor
    private func fakeSSHManager(lsofExecutable: String = "/usr/bin/false") throws -> TunnelManager {
        let bin = temporaryHome.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ssh = bin.appendingPathComponent("ssh")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        return manager(environment: ["PATH": bin.path + ":/usr/bin:/bin"], lsofExecutable: lsofExecutable)
    }

    @MainActor
    func testStopRestartAndLateExitCannotClearNewProcess() async throws {
        let manager = try fakeSSHManager()
        let tunnel = TunnelConfig(name: "Lifecycle", localPorts: [59992], remoteTargets: ["localhost:443"], sshHost: "unused")
        manager.tunnels = [tunnel]
        manager.startTunnel(for: tunnel.id)
        let old = try XCTUnwrap(manager.processes[tunnel.id])
        let lateExit = try XCTUnwrap(old.terminationHandler)
        manager.stopTunnel(for: tunnel.id)
        XCTAssertTrue(manager.stoppingPorts.contains(59992))
        manager.startTunnel(for: tunnel.id)
        XCTAssertTrue(manager.processes[tunnel.id] === old)
        await drain(manager)
        try await waitUntil { manager.processes[tunnel.id] == nil }
        manager.startTunnel(for: tunnel.id)
        let current = try XCTUnwrap(manager.processes[tunnel.id])
        XCTAssertFalse(current === old)
        lateExit(old)
        await Task.yield()
        await drain(manager)
        XCTAssertTrue(manager.processes[tunnel.id] === current)
        XCTAssertTrue(current.isRunning)
        manager.stopAllTunnels()
        await drain(manager)
        XCTAssertFalse(current.isRunning)
    }

    @MainActor
    func testStopAllHandlesMultipleProcesses() async throws {
        let manager = try fakeSSHManager()
        manager.tunnels = (59993...59995).map {
            TunnelConfig(name: "Tunnel \($0)", localPorts: [$0], remoteTargets: ["localhost:443"], sshHost: "unused")
        }
        for tunnel in manager.tunnels { manager.startTunnel(for: tunnel.id) }
        let tasks = Array(manager.processes.values)
        XCTAssertEqual(tasks.count, 3)
        manager.stopAllTunnels()
        await drain(manager)
        XCTAssertTrue(tasks.allSatisfy { !$0.isRunning })
        XCTAssertTrue(manager.stoppingPorts.isEmpty)
    }

    @MainActor
    func testSocksRestartIgnoresPreviousExitCallback() async throws {
        let manager = try fakeSSHManager()
        manager.startSocks()
        let old = try XCTUnwrap(manager.socksProcess)
        let lateExit = try XCTUnwrap(old.terminationHandler)
        manager.stopSocks()
        manager.startSocks()
        XCTAssertTrue(manager.socksProcess === old)
        await drain(manager)
        try await waitUntil { manager.socksProcess == nil }
        manager.startSocks()
        let current = try XCTUnwrap(manager.socksProcess)
        lateExit(old)
        await Task.yield()
        await drain(manager)
        XCTAssertTrue(manager.socksProcess === current)
        XCTAssertTrue(current.isRunning)
        manager.stopSocks()
        await drain(manager)
        XCTAssertFalse(current.isRunning)
    }

    @MainActor
    func testProxyCleanupOnlyDisablesLocalPort1080() async throws {
        let tool = temporaryHome.appendingPathComponent("networksetup")
        let trace = temporaryHome.appendingPathComponent("disabled-services")
        let script = """
        #!/bin/sh
        case "$1" in
          -listallnetworkservices) printf 'Wi-Fi\\nRemoteProxy\\nOtherPort\\nIPv6\\n' ;;
          -getsocksfirewallproxy)
            case "$2" in
              Wi-Fi) printf 'Server: localhost\\nPort: 1080\\n' ;;
              RemoteProxy) printf 'Server: proxy.example.com\\nPort: 1080\\n' ;;
              OtherPort) printf 'Server: 127.0.0.1\\nPort: 1081\\n' ;;
              IPv6) printf 'Server: ::1\\nPort: 1080\\n' ;;
            esac ;;
          -setsocksfirewallproxystate) printf '%s\\n' "$2" >> "$(dirname "$0")/disabled-services" ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let manager = TunnelManager(startRuntime: false, homeDirectory: temporaryHome,
                                    networkSetupExecutable: tool.path, lsofExecutable: "/usr/bin/false")
        manager.stopSocks()
        await drain(manager)
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8), "Wi-Fi\nIPv6\n")
    }

    @MainActor
    func testRefreshAndShutdownAreSerializedWithProcessCallbacks() async throws {
        let manager = try fakeSSHManager()
        let tunnel = TunnelConfig(name: "Refresh", localPorts: [59996], remoteTargets: ["localhost:443"], sshHost: "unused")
        manager.tunnels = [tunnel]
        manager.startTunnel(for: tunnel.id)
        let task = try XCTUnwrap(manager.processes[tunnel.id])
        manager.refreshStatusFromSystem()
        manager.refreshAll()
        // Yield to the queued Refresh action before waiting for its I/O.
        await Task.yield()
        try await waitUntil { !task.isRunning }
        await drain(manager)
        await drain(manager)
        let shutdown = expectation(description: "Shutdown waits for cleanup")
        manager.cleanupSystemProxyOnExit { shutdown.fulfill() }
        await fulfillment(of: [shutdown], timeout: 10)
        XCTAssertFalse(task.isRunning)
        XCTAssertFalse(manager.isSocksActive)
        XCTAssertTrue(manager.tunnels.isEmpty)
        manager.startSocks()
        XCTAssertFalse(manager.isSocksActive, "Shutdown must reject new work")
    }

    @MainActor
    func testInstalledConfigsWhenExplicitlyProvided() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PROXYMB_CONFIG_FIXTURE_DIRECTORY"] else {
            throw XCTSkip("Set PROXYMB_CONFIG_FIXTURE_DIRECTORY to validate installed configs read-only")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        let manager = manager()
        for file in files {
            XCTAssertNoThrow(try manager.decodeConfigItems(from: Data(contentsOf: file)), file.lastPathComponent)
        }
    }
}
