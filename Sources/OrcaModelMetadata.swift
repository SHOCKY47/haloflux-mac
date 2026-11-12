import Foundation
import SQLite3

/// Optional model enrichment from Orca's own, exact pane/session metadata.
/// Called only on OrcaStateBridge's utility queue. It reads no conversation,
/// terminal transcript, provider configuration, credential, or rollout content.
final class OrcaModelMetadata {
    struct Key: Hashable {
        let workspaceID: String
        let paneKey: String
        let agentType: String
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var nextRefresh: TimeInterval = 0
    private var requested = Set<Key>()
    private var cached: [Key: String] = [:]
    private var trackedDatabases: [URL] = []
    private var lastSignature = ""
    private var readFailed = false
    private var statusDatabase: URL {
        home.appendingPathComponent("Library/Application Support/orca/agent-hooks/last-status.db")
    }

    func reset() {
        nextRefresh = 0
        requested.removeAll()
        cached.removeAll()
        trackedDatabases.removeAll()
        lastSignature = ""
    }

    static func key(workspace: [String: Any], agent: [String: Any]) -> Key? {
        // Old local rows omit executionHostId. Exact local hook ownership still
        // has to match both workspace ID and the complete pane key below.
        let identity = workspace["identity"] as? [String: Any]
        if let host = identity?["executionHostId"] as? String, host != "local" { return nil }
        if let host = workspace["executionHostId"] as? String, host != "local" { return nil }
        guard let workspaceID = workspace["worktreeId"] as? String,
              let paneKey = agent["paneKey"] as? String,
              let agentType = agent["agentType"] as? String,
              !workspaceID.isEmpty, workspaceID.utf8.count <= 4096,
              !paneKey.isEmpty, paneKey.utf8.count <= 512,
              !agentType.isEmpty, agentType.utf8.count <= 120 else { return nil }
        return Key(workspaceID: workspaceID, paneKey: paneKey, agentType: agentType)
    }

    static func validatedModel(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 120,
              value.rangeOfCharacter(from: .newlines.union(.controlCharacters)) == nil else { return nil }
        let unresolved = ["auto", "automatic", "default", "unknown", "unspecified"]
        return unresolved.contains(value.lowercased()) ? nil : value
    }

    func models(for workspaces: [[String: Any]]) -> [Key: String] {
        let keys = Set(workspaces.flatMap { workspace in
            (workspace["agents"] as? [[String: Any]] ?? []).compactMap { agent -> Key? in
                guard Self.validatedModel(agent["model"]) == nil else { return nil }
                return Self.key(workspace: workspace, agent: agent)
            }
        })
        guard !keys.isEmpty, keys.count <= 128 else { return [:] }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextRefresh else { return cached.filter { keys.contains($0.key) } }
        nextRefresh = now + 10
        let signature = fileSignature([statusDatabase] + trackedDatabases)
        if keys == requested, signature == lastSignature { return cached }

        requested = keys
        readFailed = false
        var values: [Key: String] = [:]
        var databases = Set<URL>()
        for key in keys {
            guard let hook = latestHook(for: key) else { continue }
            if hook.mainModelIsVerified, let model = Self.validatedModel(hook.model) {
                values[key] = model
                continue
            }
            guard key.agentType == "codex", hook.sessionKey == "session_id",
                  let sessionID = hook.sessionID, !sessionID.isEmpty, sessionID.utf8.count <= 128,
                  let transcriptPath = hook.transcriptPath,
                  let database = codexDatabase(for: transcriptPath) else { continue }
            databases.insert(database)
            // The exact transcript path also disambiguates a thread copied to
            // another account. The transcript itself is never opened or read.
            let rows = query(database, sql: "SELECT model FROM threads WHERE id = ? AND rollout_path = ? LIMIT 2",
                             bindings: [sessionID, transcriptPath])
            if let rows, rows.count == 1, let model = Self.validatedModel(rows[0][0]) {
                values[key] = model
            }
        }
        cached = values
        trackedDatabases = Array(databases)
        // Keep the signature sampled before reads. A write during a read must
        // invalidate the next refresh, rather than bless an older snapshot.
        // A busy/missing/incompatible database is not a successful empty
        // snapshot. Retry at the next TTL even if its file signature is stable.
        lastSignature = readFailed ? "" : signature
        return values
    }

    private struct Hook: Equatable {
        let sessionKey: String?
        let sessionID: String?
        let transcriptPath: String?
        let model: String?
        let receivedAt: Double
        let mainModelIsVerified: Bool
    }

    private func latestHook(for key: Key) -> Hook? {
        // Extract only this whitelist inside SQLite. Never SELECT value: the
        // JSON document also contains prompts and tool inputs.
        let sql = """
        SELECT json_extract(value, '$.providerSession.key'),
               json_extract(value, '$.providerSession.id'),
               json_extract(value, '$.providerSession.transcriptPath'),
               json_extract(value, '$.payload.model'),
               json_extract(value, '$.receivedAt'),
               json_extract(value, '$.hookEventName'),
               json_extract(value, '$.toolAgentId'),
               json_extract(value, '$.toolAgentType'),
               json_extract(value, '$.agentPresence.session'),
               COALESCE(json_array_length(value, '$.payload.subagents'), 0)
        FROM rows
        WHERE json_valid(value)
          AND json_extract(value, '$.worktreeId') = ?
          AND json_extract(value, '$.paneKey') = ?
          AND json_extract(value, '$.agentPresence.agent') = ?
        ORDER BY json_extract(value, '$.receivedAt') DESC
        LIMIT 2
        """
        guard let rows = query(statusDatabase, sql: sql,
                               bindings: [key.workspaceID, key.paneKey, key.agentType]) else { return nil }
        let hooks = rows.compactMap { row -> Hook? in
            guard row.count == 10, let rawTime = row[4], let time = Double(rawTime),
                  time.isFinite, time >= 0, let sessionID = row[1], !sessionID.isEmpty,
                  row[8] == sessionID else { return nil }
            let mainModelIsVerified = ["Stop", "PermissionRequest"].contains(row[5] ?? "")
                && row[6] == nil && row[7] == nil && row[1] != nil && row[8] == row[1]
                && row[9] == "0"
            return Hook(sessionKey: row[0], sessionID: row[1], transcriptPath: row[2],
                        model: row[3], receivedAt: time, mainModelIsVerified: mainModelIsVerified)
        }
        guard hooks.count == rows.count, let newest = hooks.first else { return nil }
        // A tied latest record has no unique owner. Do not pick by row order.
        if hooks.count > 1, hooks[1].receivedAt == newest.receivedAt { return nil }
        return newest
    }

    private func codexDatabase(for transcriptPath: String) -> URL? {
        guard transcriptPath.hasPrefix("/"), transcriptPath.utf8.count <= 4096,
              transcriptPath.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let transcript = URL(fileURLWithPath: transcriptPath).standardizedFileURL
        let parts = transcript.pathComponents
        let accounts = home.appendingPathComponent("Library/Application Support/orca/codex-accounts").standardizedFileURL
        let prefix = accounts.pathComponents
        if parts.count > prefix.count + 3, Array(parts.prefix(prefix.count)) == prefix {
            let account = parts[prefix.count]
            guard UUID(uuidString: account) != nil, parts[prefix.count + 1] == "home",
                  parts[prefix.count + 2] == "sessions" else { return nil }
            return accounts.appendingPathComponent(account).appendingPathComponent("home/state_5.sqlite")
        }
        let defaultHome = home.appendingPathComponent(".codex").standardizedFileURL
        let defaultPrefix = defaultHome.appendingPathComponent("sessions").pathComponents
        guard parts.count > defaultPrefix.count,
              Array(parts.prefix(defaultPrefix.count)) == defaultPrefix else { return nil }
        return defaultHome.appendingPathComponent("state_5.sqlite")
    }

    private func query(_ database: URL, sql: String, bindings: [String]) -> [[String?]]? {
        var succeeded = false
        defer { if !succeeded { readFailed = true } }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 25)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { return nil }
        }
        var rows: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { succeeded = true; return rows }
            guard status == SQLITE_ROW, rows.count < 2 else { return nil }
            var row: [String?] = []
            for index in 0..<sqlite3_column_count(statement) {
                guard sqlite3_column_bytes(statement, index) <= 8192 else { return nil }
                if sqlite3_column_type(statement, index) == SQLITE_NULL { row.append(nil) }
                else if let value = sqlite3_column_text(statement, index) {
                    let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index)))
                    guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
                    row.append(text)
                }
                else { return nil }
            }
            rows.append(row)
        }
    }

    private func fileSignature(_ databases: [URL]) -> String {
        databases.flatMap { [$0.path, $0.path + "-wal"] }.sorted().map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let time = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            return "\(path):\(time):\(size)"
        }.joined(separator: "\n")
    }
}
