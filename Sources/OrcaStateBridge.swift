import Foundation
import CoreFoundation
import Darwin

/// Read-only Orca status adapter. Public lifecycle methods may be called from any
/// queue; assign `onUpdate` on the main thread. Every callback is on the main thread.
/// The only subprocess command is `orca worktree ps --limit 10000 --json`.
final class OrcaStateBridge: @unchecked Sendable {
    var onUpdate: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "local.haloflux.orca-state", qos: .utility)
    // Finder/login launches do not inherit an interactive shell's PATH.
    private var executableURL: URL? {
        if let configured = UserDefaults.standard.string(forKey: "orcaCLIPath"), !configured.isEmpty {
            // An explicit override never silently falls back to a different CLI.
            guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else { return nil }
            return URL(fileURLWithPath: configured)
        }
        return ["/usr/local/bin/orca", "/opt/homebrew/bin/orca"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
    private let interval: TimeInterval = 1.8
    private let timeout: TimeInterval = 6
    private let maximumOutputBytes = 16 * 1024 * 1024
    private let delivery = DeliveryGate()
    private let modelMetadata = OrcaModelMetadata()
    private let attentionMetadata = OrcaAttentionMetadata()
    private var timer: DispatchSourceTimer?
    private var poll: Poll?
    private var started = false
    private var paused = false
    private var sourceAvailable = true
    private var refreshAfterExit = false
    private var generation: UInt64 = 0

    private final class Poll: @unchecked Sendable {
        let process = Process()
        let output = Pipe()
        let generation: UInt64
        var reader: DispatchSourceRead?
        var deadline: DispatchWorkItem?
        var data = Data()
        var failure: String?
        var discard = false

        init(generation: UInt64) { self.generation = generation }
    }

    /// Prevent queued callbacks from a stopped or paused generation reaching UI.
    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func set(_ generation: UInt64) { lock.lock(); value = generation; lock.unlock() }
        func contains(_ generation: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return value == generation
        }
    }

    deinit {
        timer?.cancel()
        guard let current = poll else { return }
        current.deadline?.cancel()
        current.reader?.cancel()
        if current.reader == nil { try? current.output.fileHandleForReading.close() }
        try? current.output.fileHandleForWriting.close()
        current.process.terminationHandler = nil
        if current.process.isRunning {
            current.process.terminate()
            queue.asyncAfter(deadline: .now() + 0.4) {
                if current.process.isRunning { _ = Darwin.kill(current.process.processIdentifier, SIGKILL) }
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.advanceGeneration()
            if !self.sourceAvailable {
                self.publishFailure("orca_not_running", generation: self.generation)
            } else if !self.paused { self.schedule() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.modelMetadata.reset()
            self.attentionMetadata.reset()
            self.refreshAfterExit = false
            self.advanceGeneration()
            self.unschedule()
            self.cancelCurrentPoll()
        }
    }

    func setPaused(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.paused != value else { return }
            self.paused = value
            self.advanceGeneration()
            self.unschedule()
            if value { self.cancelCurrentPoll() }
            else if self.started {
                if self.sourceAvailable {
                    self.refreshAfterExit = self.poll != nil
                    self.schedule()
                } else { self.publishFailure("orca_not_running", generation: self.generation) }
            }
        }
    }

    /// The native host observes Orca's application lifecycle. Absence suspends
    /// CLI work and clears stale state; availability resumes read-only polling.
    /// This method never launches Orca or changes any Orca workspace.
    func setSourceAvailable(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.sourceAvailable != value else { return }
            self.sourceAvailable = value
            self.advanceGeneration()
            self.unschedule()
            self.refreshAfterExit = false
            if !value {
                self.modelMetadata.reset()
                self.attentionMetadata.reset()
                self.cancelCurrentPoll()
                if self.started { self.publishFailure("orca_not_running", generation: self.generation) }
            } else if self.started, !self.paused {
                self.refreshAfterExit = self.poll != nil
                self.schedule()
            }
        }
    }

    private func advanceGeneration() {
        generation &+= 1
        delivery.set(generation)
    }

    private func schedule() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(150))
        source.setEventHandler { [weak self] in self?.beginPoll() }
        timer = source
        source.resume()
    }

    private func unschedule() { timer?.cancel(); timer = nil }

    private func beginPoll() {
        // A slow CLI call never overlaps another call, including while it exits.
        guard started, !paused, sourceAvailable, poll == nil else { return }
        guard let executableURL else {
            publishFailure("cli_missing", generation: generation)
            return
        }
        let current = Poll(generation: generation)
        poll = current
        current.process.executableURL = executableURL
        current.process.arguments = ["worktree", "ps", "--limit", "10000", "--json"]
        current.process.standardInput = FileHandle.nullDevice
        current.process.standardOutput = current.output
        // Do not retain or expose Electron diagnostics, commands, or prompt text.
        current.process.standardError = FileHandle.nullDevice
        current.process.terminationHandler = { [weak self, weak current] _ in
            guard let self, let current else { return }
            self.queue.async { [weak self] in self?.finish(current) }
        }

        let descriptor = current.output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            cleanup(current)
            publishFailure("pipe_unavailable", generation: current.generation)
            return
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self, weak current] in
            guard let self, let current else { return }
            self.drain(current)
        }
        reader.setCancelHandler { [output = current.output] in
            try? output.fileHandleForReading.close()
        }
        current.reader = reader
        reader.resume()

        do {
            try current.process.run()
            try? current.output.fileHandleForWriting.close()
        } catch {
            cleanup(current)
            publishFailure("cli_launch_failed", generation: current.generation)
            return
        }
        let deadline = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, self.poll === current else { return }
            self.failAndTerminate(current, reason: "cli_timeout")
        }
        current.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }

    private func drain(_ current: Poll) {
        guard poll === current, current.reader != nil else { return }
        let descriptor = current.output.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // The FD is nonblocking. Draining stdout while the child runs prevents a
        // full pipe from deadlocking Process, without blocking the timer queue.
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                guard !current.discard else { continue }
                guard current.data.count <= maximumOutputBytes - count else {
                    failAndTerminate(current, reason: "output_too_large")
                    return
                }
                current.data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                current.reader?.cancel()
                current.reader = nil
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                failAndTerminate(current, reason: "output_read_failed")
                return
            }
        }
    }

    private func failAndTerminate(_ current: Poll, reason: String) {
        guard poll === current, current.failure == nil else { return }
        current.failure = reason
        current.discard = true
        current.data.removeAll(keepingCapacity: false)
        publishFailure(reason, generation: current.generation)
        terminateOwnChild(current)
    }

    private func cancelCurrentPoll() {
        guard let current = poll else { return }
        current.discard = true
        current.data.removeAll(keepingCapacity: false)
        current.deadline?.cancel()
        terminateOwnChild(current)
    }

    private func terminateOwnChild(_ current: Poll) {
        guard current.process.isRunning else { return }
        current.process.terminate()
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self, weak current] in
            guard let self, let current, self.poll === current,
                  current.process.isRunning else { return }
            // Only this Process's still-running PID is signalled; never Orca.app,
            // an agent PTY, a process group, or a process found by name.
            _ = Darwin.kill(current.process.processIdentifier, SIGKILL)
        }
    }

    private func finish(_ current: Poll) {
        guard poll === current else { return }
        drain(current)
        let data = current.data
        let shouldDeliver = !current.discard && started && !paused
            && current.generation == generation
        let status = current.process.terminationStatus
        cleanup(current)
        if refreshAfterExit {
            refreshAfterExit = false
            beginPoll()
        }
        guard shouldDeliver else { return }

        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            publishFailure(status == 0 ? "invalid_json" : "cli_exit_\(status)", generation: current.generation)
            return
        }
        guard envelope["ok"] as? Bool == true else {
            let error = envelope["error"] as? [String: Any]
            let code = Self.string(error?["code"]) ?? "request_failed"
            let safeCode = String(code.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(80))
            publishFailure("orca_\(safeCode)", generation: current.generation)
            return
        }
        guard status == 0, let result = envelope["result"] as? [String: Any],
              let rows = result["worktrees"] as? [[String: Any]] else {
            publishFailure("unsupported_response", generation: current.generation)
            return
        }
        guard result["truncated"] as? Bool != true else {
            publishFailure("result_truncated", generation: current.generation)
            return
        }
        let models = modelMetadata.models(for: rows)
        let requests = attentionMetadata.requests(for: rows)
        let workspaces = rows.compactMap { Self.workspace($0, models: models, requests: requests) }
        if !rows.isEmpty && workspaces.isEmpty {
            publishFailure("unsupported_workspace_schema", generation: current.generation)
            return
        }
        // UI activity comes from isActive; never infer it from cwd or recency.
        let active = workspaces.first { $0["isActive"] as? Bool == true }?["id"]
        publish([
            "version": 1, "connected": true, "observedAt": Self.now(),
            "activeWorkspaceId": active ?? NSNull(), "workspaces": workspaces,
            "error": NSNull(),
        ], generation: current.generation)
    }

    private func cleanup(_ current: Poll) {
        current.deadline?.cancel()
        current.deadline = nil
        if current.reader == nil { try? current.output.fileHandleForReading.close() }
        current.reader?.cancel()
        current.reader = nil
        try? current.output.fileHandleForWriting.close()
        current.process.terminationHandler = nil
        if poll === current { poll = nil }
    }

    private func publishFailure(_ error: String, generation: UInt64) {
        publish([
            "version": 1, "connected": false, "observedAt": Self.now(),
            "activeWorkspaceId": NSNull(), "workspaces": [[String: Any]](), "error": error,
        ], generation: generation)
    }

    private func publish(_ state: [String: Any], generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.delivery.contains(generation) else { return }
            self.onUpdate?(state)
        }
    }

    private static func workspace(_ row: [String: Any], models: [OrcaModelMetadata.Key: String], requests: OrcaAttentionMetadata.Requests) -> [String: Any]? {
        let identity = row["identity"] as? [String: Any]
        guard let id = string(identity?["key"]) ?? string(row["worktreeId"])
                ?? string(row["folderId"]) else { return nil }
        let path = string(row["path"]) ?? ""
        let name = string(row["displayName"]) ?? string(row["name"])
            ?? (path.isEmpty ? id : URL(fileURLWithPath: path).lastPathComponent)
        var agents: [[String: Any]] = []
        var ids = Set<String>()
        for agent in row["agents"] as? [[String: Any]] ?? [] {
            guard let pane = string(agent["paneKey"]) else { continue }
            let agentID = id + "/" + pane
            guard ids.insert(agentID).inserted else { continue }
            let main = agent["mainAgent"] as? [String: Any]
            let type = string(agent["agentType"]) ?? "unknown"
            let metadataModel = OrcaModelMetadata.key(workspace: row, agent: agent).flatMap { models[$0] }
            let attention = OrcaModelMetadata.key(workspace: row, agent: agent).flatMap { requests[$0] } ?? [:]
            let resolvedModel = OrcaModelMetadata.validatedModel(agent["model"]) ?? metadataModel
            let model: Any = resolvedModel as Any? ?? NSNull()
            let title = string(agent["taskTitle"]) ?? string(agent["displayName"])
                ?? string(agent["conversationName"]) ?? type
            var value: [String: Any] = [
                "id": agentID,
                "parentId": string(agent["parentPaneKey"]).map { id + "/" + $0 } as Any? ?? NSNull(),
                "type": type, "title": String(title.prefix(100)),
                "modelId": model, "modelDisplayName": model,
                "needsInput": attention[""] != nil,
                "attentionReason": attention[""] as Any? ?? NSNull(),
                "state": string(main?["state"]) ?? string(agent["state"]) ?? "unknown",
                "outcome": outcome(main?["outcome"]),
                "interrupted": boolean(agent["interrupted"]),
                "toolName": string(agent["toolName"]) as Any? ?? NSNull(),
                "updatedAt": timestamp(agent["updatedAt"]),
                "stateStartedAt": timestamp(main?["stateStartedAt"] ?? agent["stateStartedAt"]),
                "hasLivePty": agent["hasLivePty"] as? Bool ?? false,
            ]
            if let activity = agent["activity"] as? [String: Any] {
                // Activity metadata is evidence from Orca. Its title can contain
                // message content, so only these status fields cross the bridge.
                var safe: [String: Any] = [:]
                for key in ["listed", "unread", "clearable"] {
                    if let flag = activity[key] as? Bool { safe[key] = flag }
                }
                if let status = string(activity["status"]) { safe["status"] = status }
                if activity["sortAt"] is NSNumber { safe["sortAt"] = timestamp(activity["sortAt"]) }
                value["activity"] = safe
            }
            agents.append(value)
            for child in agent["subagents"] as? [[String: Any]] ?? [] {
                guard let childID = string(child["id"]) else { continue }
                let fullID = agentID + "/subagent:" + childID
                guard ids.insert(fullID).inserted else { continue }
                let childType = string(child["agentType"]) ?? type
                let childModel = modelIdentifier(child["model"])
                let description = string(child["description"])
                // Long/multiline descriptions can be complete prompts. Do not
                // truncate those into a misleading task title; use an ID label.
                let shortDescription = description.flatMap { text -> String? in
                    guard text.count <= 100, !text.contains("\n"), !text.contains("\r") else { return nil }
                    return text
                }
                let childTitle = shortDescription ?? "\(childType) · \(childID.prefix(8))"
                agents.append([
                    "id": fullID, "parentId": agentID, "type": childType,
                    "title": String(childTitle.prefix(100)),
                    "modelId": childModel, "modelDisplayName": childModel,
                    "needsInput": attention[childID] != nil,
                    "attentionReason": attention[childID] as Any? ?? NSNull(),
                    "state": string(child["state"]) ?? "unknown",
                    "outcome": outcome(child["outcome"]),
                    "interrupted": boolean(child["interrupted"]),
                    "toolName": NSNull(), "updatedAt": timestamp(child["updatedAt"]),
                    // Legacy startedAt is the child's birth time, not a state
                    // transition or evidence update. Keep absent clocks unknown.
                    "stateStartedAt": timestamp(child["stateStartedAt"]),
                    "hasLivePty": child["hasLivePty"] as? Bool ?? false,
                ])
            }
        }
        return [
            "id": id, "name": String(name.prefix(100)), "project": string(row["repo"]) ?? "",
            "path": path, "branch": string(row["branch"]) as Any? ?? NSNull(),
            "status": string(row["status"]) ?? string(row["workspaceStatus"]) ?? "unknown",
            "isActive": row["isActive"] as? Bool ?? false,
            "lastActivityAt": timestamp(row["lastActivityAt"]), "agents": agents,
        ]
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func timestamp(_ value: Any?) -> Any {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return NSNull() }
        return number
    }
    private static func modelIdentifier(_ value: Any?) -> Any {
        // Orca preserves an optional model string separately from agentType.
        // Keep the actual identifier (including its version), without inferring
        // a model from a client, parent, child, or global default setting.
        return OrcaModelMetadata.validatedModel(value) as Any? ?? NSNull()
    }
    private static func boolean(_ value: Any?) -> Any {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return NSNull() }
        return number.boolValue
    }
    private static func outcome(_ value: Any?) -> Any {
        // Source: Orca's AGENT_TURN_OUTCOMES in agent-turn-outcome.js. Absence
        // or a future value is unknown; neither may imply successful completion.
        let known = ["success", "failure", "cancellation", "superseded", "interruption", "unconfirmed"]
        guard let value = string(value), known.contains(value) else { return NSNull() }
        return value
    }
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
