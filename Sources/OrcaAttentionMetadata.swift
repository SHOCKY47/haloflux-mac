import Foundation
import SQLite3
import Darwin

/// Read-only, local metadata projection for requests that actually need a person.
/// Runs on the bridge utility queue. No text, tool arguments or transcript rows
/// leave this class; only a request kind survives each bounded parse.
final class OrcaAttentionMetadata {
    typealias Pane = OrcaModelMetadata.Key
    // The empty child ID denotes the main agent; other IDs are exact subagent IDs.
    typealias Requests = [Pane: [String: String]]

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private struct SessionKey: Hashable {
        let pane: Pane
        let session: String
    }
    private var cursors: [SessionKey: Cursor] = [:]
    private let tailLimit = 8 * 1024 * 1024
    private let lineLimit = 1024 * 1024

    private final class Cursor {
        let session: String
        let path: String
        let inode: UInt64
        let device: UInt64
        let parentSession: String?
        var offset: UInt64
        var discardLine: Bool
        var fragment = Data()
        var pending = false
        var calls = Set<String>()
        var historyStart: UInt64
        var historyComplete: Bool
        var needsInitialBoundary: Bool

        init(session: String, path: String, inode: UInt64, device: UInt64, offset: UInt64, parentSession: String? = nil) {
            self.session = session; self.path = path
            self.inode = inode; self.device = device; self.offset = offset
            self.parentSession = parentSession
            discardLine = offset > 0
            historyStart = offset; historyComplete = offset == 0
            needsInitialBoundary = offset > 0
        }

        func clear() { pending = false; calls.removeAll() }
        func humanBoundary() { clear(); historyComplete = true }
    }

    private struct Hook {
        let session: String
        let path: String?
        let event: String?
        let child: String?
        let tool: String?
        let approval: Bool
        let question: Bool
    }

    func reset() { cursors.removeAll() }

    func requests(for workspaces: [[String: Any]]) -> Requests {
        var wanted = Set<Pane>()
        var sessions = Set<SessionKey>()
        var result: Requests = [:]
        var budget = 16 * 1024 * 1024
        let database = home.appendingPathComponent("Library/Application Support/orca/agent-hooks/last-status.db")
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return [:]
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 25)
        for workspace in workspaces {
            for agent in workspace["agents"] as? [[String: Any]] ?? [] {
                guard wanted.count < 128,
                      let key = OrcaModelMetadata.key(workspace: workspace, agent: agent) else { continue }
                wanted.insert(key)
                guard agent["hasLivePty"] as? Bool == true,
                      let hook = latestHook(connection, key: key) else {
                    continue
                }
                let main = agent["mainAgent"] as? [String: Any]
                let state = main?["state"] as? String ?? agent["state"] as? String
                var kinds: [String: String] = [:]
                // Root interactivePrompt is cleared by the next root tool/turn
                // event. Child hooks preserve it, so their event must not mask
                // a root request that is still waiting.
                if state == "waiting" || state == "blocked" {
                    if hook.approval { kinds[""] = "approval" }
                    else if hook.question { kinds[""] = "question" }
                    else if hook.child == nil {
                        if hook.event == "PermissionRequest" { kinds[""] = "approval" }
                        else if hook.event == "PreToolUse", Self.isBlockingQuestion(hook.tool) {
                            kinds[""] = "question"
                        }
                    }
                }
                // Never attribute a child's approval to the main agent merely
                // because the aggregate pane status says waiting.
                if main == nil, key.agentType == "codex",
                   !(agent["subagents"] as? [[String: Any]] ?? []).isEmpty {
                    kinds.removeValue(forKey: "")
                }
                if let childID = hook.child,
                   let child = (agent["subagents"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == childID }),
                   child["state"] as? String == "waiting" {
                    if hook.event == "PermissionRequest" { kinds[childID] = "approval" }
                    else if hook.event == "PreToolUse", Self.isBlockingQuestion(hook.tool) {
                        kinds[childID] = "question"
                    }
                }
                if key.agentType == "codex", let path = hook.path {
                    sessions.insert(SessionKey(pane: key, session: hook.session))
                    if asyncQuestion(key: key, session: hook.session, path: path, budget: &budget), kinds[""] == nil {
                        // An approval takes precedence while both requests exist.
                        kinds[""] = "question"
                    }
                    let children = agent["subagents"] as? [[String: Any]] ?? []
                    for child in childSessions(children, parentSession: hook.session, parentPath: path) {
                        sessions.insert(SessionKey(pane: key, session: child.id))
                        if asyncQuestion(key: key, session: child.id, path: child.path,
                                         parentSession: child.parent, budget: &budget), kinds[child.id] == nil {
                            kinds[child.id] = "question"
                        }
                    }
                }
                if !kinds.isEmpty { result[key] = kinds }
            }
        }
        cursors = cursors.filter { sessions.contains($0.key) }
        return result
    }

    private struct ChildSession {
        let id: String
        let path: String
        let parent: String
    }

    private func transcriptHome(_ url: URL) -> URL? {
        let parts = url.pathComponents
        let accounts = home.appendingPathComponent("Library/Application Support/orca/codex-accounts").resolvingSymlinksInPath()
        let prefix = accounts.pathComponents
        if parts.count > prefix.count + 3, Array(parts.prefix(prefix.count)) == prefix,
           UUID(uuidString: parts[prefix.count]) != nil,
           parts[prefix.count + 1] == "home", parts[prefix.count + 2] == "sessions" {
            return accounts.appendingPathComponent(parts[prefix.count]).appendingPathComponent("home")
        }
        let normal = home.appendingPathComponent(".codex").resolvingSymlinksInPath()
        let normalPrefix = normal.appendingPathComponent("sessions").pathComponents
        return parts.count > normalPrefix.count && Array(parts.prefix(normalPrefix.count)) == normalPrefix ? normal : nil
    }

    private func childSessions(_ agents: [[String: Any]], parentSession: String, parentPath: String) -> [ChildSession] {
        let ids = Set(agents.compactMap { $0["id"] as? String }.filter { UUID(uuidString: $0) != nil })
        guard !ids.isEmpty, ids.count <= 128,
              let parentURL = permittedTranscript(parentPath, session: parentSession),
              let account = transcriptHome(parentURL) else { return [] }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(account.appendingPathComponent("state_5.sqlite").path, &connection,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            return []
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 25)
        // Follow only recorded spawn edges in this exact account. A descendant
        // must reach the current root session, and its own source must agree
        // with its immediate parent edge. No other account or directory is searched.
        let sql = """
        WITH RECURSIVE lineage(id, depth) AS (
          SELECT ?1, 0
          UNION ALL
          SELECT e.parent_thread_id, l.depth + 1
          FROM thread_spawn_edges e JOIN lineage l ON e.child_thread_id = l.id
          WHERE l.depth < 16
        )
        SELECT t.rollout_path, e.parent_thread_id
        FROM threads t JOIN thread_spawn_edges e ON e.child_thread_id = t.id
        WHERE t.id = ?1
          AND json_extract(CASE WHEN json_valid(t.source) THEN t.source ELSE '{}' END,
                           '$.subagent.thread_spawn.parent_thread_id') = e.parent_thread_id
          AND EXISTS (SELECT 1 FROM lineage WHERE id = ?2 AND depth > 0)
        LIMIT 2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var children: [ChildSession] = []
        for id in ids.sorted() {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, parentSession, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_bytes(statement, 0) <= 4096, sqlite3_column_bytes(statement, 1) <= 128,
                  let rawPath = sqlite3_column_text(statement, 0),
                  let rawParent = sqlite3_column_text(statement, 1) else { continue }
            let path = String(cString: rawPath), parent = String(cString: rawParent)
            guard sqlite3_step(statement) == SQLITE_DONE, UUID(uuidString: parent) != nil,
                  let url = permittedTranscript(path, session: id), transcriptHome(url) == account else { continue }
            children.append(ChildSession(id: id, path: url.path, parent: parent))
        }
        return children
    }

    private static func isBlockingQuestion(_ tool: String?) -> Bool {
        let name = (tool ?? "").filter { $0.isLetter || $0.isNumber }.lowercased()
        return name == "askuserquestion" || name == "requestuserinput"
            || name.hasSuffix("functionsrequestuserinput")
    }

    private func latestHook(_ connection: OpaquePointer, key: Pane) -> Hook? {
        // JSON is projected inside SQLite. interactivePrompt, prompt, toolInput,
        // and assistant messages are never returned by this query.
        let sql = """
        SELECT json_extract(value, '$.providerSession.id'),
               json_extract(value, '$.agentPresence.session'),
               json_extract(value, '$.providerSession.transcriptPath'),
               json_extract(value, '$.hookEventName'),
               json_extract(value, '$.toolAgentId'),
               json_extract(value, '$.payload.toolName'),
               json_extract(value, '$.receivedAt'),
               CASE WHEN json_valid(json_extract(value, '$.payload.interactivePrompt'))
                    THEN length(json_extract(json_extract(value, '$.payload.interactivePrompt'), '$.approval.tool')) > 0 ELSE 0 END,
               CASE WHEN json_valid(json_extract(value, '$.payload.interactivePrompt'))
                    THEN json_array_length(json_extract(value, '$.payload.interactivePrompt'), '$.questions') > 0 ELSE 0 END
        FROM rows WHERE json_valid(value)
          AND json_extract(value, '$.worktreeId') = ?
          AND json_extract(value, '$.paneKey') = ?
          AND json_extract(value, '$.agentPresence.agent') = ?
        ORDER BY json_extract(value, '$.receivedAt') DESC LIMIT 2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in [key.workspaceID, key.paneKey, key.agentType].enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { return nil }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func field(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  sqlite3_column_bytes(statement, index) <= 4096,
                  let bytes = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: bytes)
        }
        guard let session = field(0), session == field(1), !session.isEmpty,
              session.utf8.count <= 128 else { return nil }
        let time = sqlite3_column_double(statement, 6)
        let hook = Hook(session: session, path: field(2), event: field(3), child: field(4), tool: field(5),
                        approval: sqlite3_column_int(statement, 7) == 1,
                        question: sqlite3_column_int(statement, 8) == 1)
        let next = sqlite3_step(statement)
        guard next == SQLITE_DONE || (next == SQLITE_ROW && sqlite3_column_double(statement, 6) < time) else { return nil }
        return hook
    }

    private func permittedTranscript(_ path: String, session: String) -> URL? {
        guard UUID(uuidString: session) != nil, path.utf8.count <= 4096,
              path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension == "jsonl", url.lastPathComponent.contains(session) else { return nil }
        let parts = url.pathComponents
        let accounts = home.appendingPathComponent("Library/Application Support/orca/codex-accounts").resolvingSymlinksInPath().pathComponents
        if parts.count > accounts.count + 3, Array(parts.prefix(accounts.count)) == accounts,
           UUID(uuidString: parts[accounts.count]) != nil,
           parts[accounts.count + 1] == "home", parts[accounts.count + 2] == "sessions" { return url }
        let normal = home.appendingPathComponent(".codex/sessions").resolvingSymlinksInPath().pathComponents
        return parts.count > normal.count && Array(parts.prefix(normal.count)) == normal ? url : nil
    }

    private func asyncQuestion(key pane: Pane, session: String, path: String, parentSession: String? = nil, budget: inout Int) -> Bool {
        let key = SessionKey(pane: pane, session: session)
        guard let url = permittedTranscript(path, session: session),
              let file = try? FileHandle(forReadingFrom: url) else {
            cursors.removeValue(forKey: key); return false
        }
        defer { try? file.close() }
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else { cursors.removeValue(forKey: key); return false }
        let size = UInt64(info.st_size), inode = UInt64(info.st_ino), device = UInt64(info.st_dev)
        var cursor = cursors[key]
        if cursor?.session != session || cursor?.path != url.path || cursor?.inode != inode
            || cursor?.device != device || cursor?.parentSession != parentSession || (cursor?.offset ?? 0) > size {
            // Confirm the exact rollout's own identity before following it.
            guard let header = readHeader(file, budget: &budget),
                  let row = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any],
                  row["type"] as? String == "session_meta",
                  let payload = row["payload"] as? [String: Any], payload["id"] as? String == session else {
                cursors.removeValue(forKey: key); return false
            }
            if let parentSession {
                let source = payload["source"] as? [String: Any]
                let subagent = source?["subagent"] as? [String: Any]
                let spawn = subagent?["thread_spawn"] as? [String: Any]
                guard spawn?["parent_thread_id"] as? String == parentSession else {
                    cursors.removeValue(forKey: key); return false
                }
            }
            let offset = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
            cursor = Cursor(session: session, path: url.path, inode: inode, device: device, offset: offset, parentSession: parentSession)
            cursors[key] = cursor
        }
        guard let cursor else { return false }
        if cursor.offset == size {
            if cursor.fragment.isEmpty, !cursor.discardLine {
                backfill(file, cursor: cursor, budget: &budget)
                return cursor.pending
            }
            return false
        }
        guard budget > 0 else { return false }
        do {
            try file.seek(toOffset: cursor.offset)
            var allowance = min(budget, tailLimit)
            while cursor.offset < size, allowance > 0 {
                let count = min(65536, allowance, Int(size - cursor.offset))
                guard let data = try file.read(upToCount: count), !data.isEmpty else { return false }
                cursor.offset += UInt64(data.count); allowance -= data.count; budget -= data.count
                consume(data, cursor: cursor)
            }
        } catch { cursors.removeValue(forKey: key); return false }
        // Never expose a historical pending flag before reaching the latest
        // complete record. The next poll continues after this byte budget.
        var after = stat()
        guard fstat(file.fileDescriptor, &after) == 0, after.st_size >= 0, UInt64(after.st_size) == cursor.offset,
              cursor.fragment.isEmpty, !cursor.discardLine else { return false }
        backfill(file, cursor: cursor, budget: &budget)
        return cursor.pending
    }

    private func readHeader(_ file: FileHandle, budget: inout Int) -> Data? {
        var header = Data()
        do {
            while header.count < lineLimit, budget > 0 {
                guard let chunk = try file.read(upToCount: min(65536, lineLimit - header.count, budget)), !chunk.isEmpty else { return nil }
                budget -= chunk.count
                if let end = chunk.firstIndex(of: 10) { header.append(chunk[..<end]); return header }
                header.append(chunk)
            }
        } catch { return nil }
        return nil
    }

    /// If the initial tail contains no human/interrupt boundary and no question,
    /// progressively inspect older metadata. Never rescan the whole large log.
    private func backfill(_ file: FileHandle, cursor: Cursor, budget: inout Int) {
        guard !cursor.pending, !cursor.historyComplete, cursor.historyStart > 0,
              budget > 0 else { return }
        let end = cursor.historyStart
        let count = min(budget, 1024 * 1024, Int(end))
        let start = end - UInt64(count)
        let older = Cursor(session: cursor.session, path: cursor.path, inode: cursor.inode,
                           device: cursor.device, offset: start)
        do {
            try file.seek(toOffset: start)
            while older.offset < end {
                guard let data = try file.read(upToCount: min(65536, Int(end - older.offset))), !data.isEmpty else { return }
                older.offset += UInt64(data.count); budget -= data.count
                consume(data, cursor: older)
            }
        } catch { return }
        // A whole lookback window inside one oversized record cannot provide
        // a reply boundary. Stop instead of rereading that same window forever.
        if older.historyStart >= end {
            if count >= lineLimit { cursor.humanBoundary() }
            return
        }
        cursor.historyStart = older.historyStart
        cursor.historyComplete = older.historyComplete || start == 0
        if older.fragment.isEmpty, !older.discardLine, older.pending {
            cursor.pending = true
            cursor.calls.formUnion(older.calls)
        }
    }

    private func consume(_ data: Data, cursor: Cursor) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            if !cursor.discardLine {
                if cursor.fragment.count + data.distance(from: start, to: end) > lineLimit {
                    // An oversized/unreadable row may contain a reply: fail
                    // closed instead of leaving a possibly obsolete alert lit.
                    cursor.fragment.removeAll(keepingCapacity: false)
                    cursor.discardLine = true; cursor.clear(); cursor.historyComplete = true
                } else { cursor.fragment.append(data[start..<end]) }
            }
            if end < data.endIndex {
                if cursor.needsInitialBoundary {
                    cursor.historyStart = cursor.offset - UInt64(data.count) + UInt64(data.distance(from: data.startIndex, to: end)) + 1
                    cursor.needsInitialBoundary = false
                }
                if !cursor.discardLine { consumeRow(cursor.fragment, cursor: cursor) }
                cursor.fragment.removeAll(keepingCapacity: true)
                cursor.discardLine = false
                start = data.index(after: end)
            } else { break }
        }
    }

    private func consumeRow(_ data: Data, cursor: Cursor) {
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            cursor.clear(); cursor.historyComplete = true; return
        }
        guard let payload = row["payload"] as? [String: Any] else { return }
        let type = row["type"] as? String, kind = payload["type"] as? String
        if type == "event_msg", kind == "turn_aborted" { cursor.humanBoundary(); return }
        guard type == "response_item" else { return }
        // Agent notices have their own type; compaction replacement histories,
        // system/developer messages and tool outputs never count as replies.
        if kind == "message", payload["role"] as? String == "user", Self.isHumanReply(payload) {
            cursor.humanBoundary(); return
        }
        guard kind == "function_call" || kind == "custom_tool_call",
              let name = payload["name"] as? String,
              name.split(separator: ".").last == "request_user_input_async",
              Self.hasAsyncQuestionShape(payload) else { return }
        if let id = payload["call_id"] as? String, id.utf8.count <= 256 {
            guard cursor.calls.insert(id).inserted else { return }
            if cursor.calls.count > 512 { cursor.calls.removeAll() }
        }
        // This tool returns "accepted" immediately. Its result and a normal
        // turn completion do not mean the human has answered the question.
        cursor.pending = true
    }

    private static func hasAsyncQuestionShape(_ payload: [String: Any]) -> Bool {
        let raw = payload["arguments"] ?? payload["input"]
        let input: [String: Any]?
        if let encoded = raw as? String, let data = encoded.data(using: .utf8) {
            input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else { input = raw as? [String: Any] }
        guard let questions = input?["questions"] as? [[String: Any]] else { return false }
        // Matches Orca's parseCodexAsyncQuestionsInput; contents are discarded.
        return questions.contains { $0["title"] is String }
    }

    private static func isHumanReply(_ payload: [String: Any]) -> Bool {
        if let source = payload["from"] as? [String: Any], source["kind"] as? String == "agent" { return false }
        if let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any],
           let kinds = metadata["content_item_kinds"] as? [String], !kinds.isEmpty {
            // Observed Codex source metadata: user.text/user.image versus
            // environments.environment_context. This needs no text inspection.
            return kinds.contains { $0.hasPrefix("user.") }
        }
        // Older providers have no origin metadata. Match Orca's bounded known
        // harness-envelope classifier; never retain or return message content.
        let blocks = payload["content"] as? [[String: Any]] ?? []
        return blocks.contains { block in
            if ["input_image", "image"].contains(block["type"] as? String ?? "") { return true }
            guard let text = block["text"] as? String else { return false }
            let head = String(text.prefix(320)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(256).lowercased()
            guard !head.isEmpty else { return false }
            let tags = ["agent-message", "bash-input", "bash-stderr", "bash-stdout", "command-args", "command-message", "command-name", "cross-session-message", "fork-boilerplate", "local-command-caveat", "local-command-stderr", "local-command-stdout", "mcp-polling-update", "mcp-resource-update", "system-reminder", "task-notification", "teammate-message", "user-memory-input", "user-prompt-submit-hook", "environment_context", "skill", "collaboration", "subagent_notification"]
            if tags.contains(where: { head.hasPrefix("<" + $0 + ">") || head.hasPrefix("<" + $0 + " ") }) { return false }
            let prefixes = ["<channel source=", "[request interrupted", "a message arrived from ", "another claude session sent a message", "no response requested.", "caveat: the messages below were generated by the user while running local commands", "this session is being continued from a previous conversation"]
            return !prefixes.contains(where: head.hasPrefix)
        }
    }
}
