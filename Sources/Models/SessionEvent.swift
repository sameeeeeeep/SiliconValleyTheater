import Foundation

// MARK: - SessionEvent

struct SessionEvent: Identifiable {
    let id = UUID()
    let type: EventType
    let summary: String      // Short display label
    let detail: String       // Rich context for dialogue generation
    let timestamp: Date
    let sessionId: String

    init(type: EventType, summary: String, detail: String = "", timestamp: Date, sessionId: String) {
        self.type = type
        self.summary = summary
        self.detail = detail.isEmpty ? summary : detail
        self.timestamp = timestamp
        self.sessionId = sessionId
    }

    enum EventType: String {
        case userMessage
        case assistantText
        case toolUse
        case toolResult
        case thinking
        case progress
        case unknown
    }
}

// MARK: - JSONL Parser

enum SessionEventParser {

    /// Parse a single JSONL line into SessionEvents (may return multiple for multi-block messages).
    static func parseAll(line: String) -> [SessionEvent] {
        guard let event = parse(line: line) else { return [] }
        return [event]
    }

    /// Parse a single JSONL line into a SessionEvent (or nil if irrelevant).
    static func parse(line: String) -> SessionEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let sessionId = json["sessionId"] as? String ?? ""
        let timestamp = parseTimestamp(json["timestamp"] as? String)
        let type = json["type"] as? String ?? ""

        // Accept user, assistant, and tool-related message types
        guard type == "user" || type == "assistant" || type == "tool_use" || type == "tool_result" else { return nil }

        guard let message = json["message"] as? [String: Any] else { return nil }
        let content = message["content"]

        // Handle content as plain string (user text messages)
        if let text = content as? String {
            let trimmed = String(text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SessionEvent(
                type: type == "user" ? .userMessage : .assistantText,
                summary: "\(type == "user" ? "User" : "Claude"): \(String(trimmed.prefix(100)))",
                detail: "\(type == "user" ? "User asked" : "Claude said"): \(trimmed)",
                timestamp: timestamp,
                sessionId: sessionId
            )
        }

        // Handle content as array of blocks — collect ALL meaningful blocks
        guard let contentArray = content as? [[String: Any]] else { return nil }

        // Collect all events from this message (multiple tool_use blocks etc)
        var events: [SessionEvent] = []

        for block in contentArray {
            guard let blockType = block["type"] as? String else { continue }

            switch blockType {
            case "text":
                let text = block["text"] as? String ?? ""
                let trimmed = String(text.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                events.append(SessionEvent(
                    type: type == "user" ? .userMessage : .assistantText,
                    summary: "Claude: \(String(trimmed.prefix(80)))",
                    detail: "Claude explains: \(trimmed)",
                    timestamp: timestamp,
                    sessionId: sessionId
                ))

            case "tool_use":
                let toolName = block["name"] as? String ?? "unknown"
                let input = block["input"] as? [String: Any] ?? [:]
                let shortSummary = summarizeToolInput(tool: toolName, input: input)
                let richDetail = richToolDetail(tool: toolName, input: input)
                events.append(SessionEvent(
                    type: .toolUse,
                    summary: "Tool: \(toolName) — \(shortSummary)",
                    detail: richDetail,
                    timestamp: timestamp,
                    sessionId: sessionId
                ))

            case "tool_result":
                var resultText = ""
                if let s = block["content"] as? String {
                    resultText = s
                } else if let arr = block["content"] as? [[String: Any]] {
                    resultText = arr.compactMap { $0["text"] as? String }.joined(separator: " ")
                }
                // Keep more of the result — test output, errors, etc are gold
                let trimmed = String(resultText.prefix(500))
                events.append(SessionEvent(
                    type: .toolResult,
                    summary: "Result: \(String(trimmed.prefix(80)))",
                    detail: "Output: \(trimmed)",
                    timestamp: timestamp,
                    sessionId: sessionId
                ))

            case "thinking":
                let thought = block["thinking"] as? String ?? ""
                if !thought.isEmpty {
                    events.append(SessionEvent(
                        type: .thinking,
                        summary: "Claude thinking...",
                        detail: "Claude's reasoning: \(String(thought.prefix(300)))",
                        timestamp: timestamp,
                        sessionId: sessionId
                    ))
                }

            default:
                continue
            }
        }

        // If multiple blocks, combine into a single event with the richest detail
        if events.count > 1 {
            // Prefer tool_use events (most interesting for commentary), combine details
            let best = events.first(where: { $0.type == .toolUse }) ?? events[0]
            let combinedDetail = events.map(\.detail).joined(separator: ". ")
            return SessionEvent(
                type: best.type,
                summary: best.summary,
                detail: String(combinedDetail.prefix(600)),
                timestamp: timestamp,
                sessionId: sessionId
            )
        }
        return events.first
    }

    // MARK: - Helpers

    private static func parseTimestamp(_ str: String?) -> Date {
        guard let str else { return Date() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str) ?? Date()
    }

    private static func summarizeToolInput(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read":
            return input["file_path"] as? String ?? "file"
        case "Write":
            let path = input["file_path"] as? String ?? "file"
            return "writing \(path)"
        case "Edit":
            let path = input["file_path"] as? String ?? "file"
            return "editing \(path)"
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            return String(cmd.prefix(80))
        case "Glob":
            return input["pattern"] as? String ?? "searching files"
        case "Grep":
            return "searching for '\(input["pattern"] as? String ?? "")'"
        case "Agent":
            return input["description"] as? String ?? "subagent"
        default:
            return String(describing: input).prefix(60).description
        }
    }

    /// Extract rich detail from tool inputs — the actual substance for dialogue gen.
    private static func richToolDetail(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read":
            let path = input["file_path"] as? String ?? "file"
            let filename = (path as NSString).lastPathComponent
            return "Reading file \(filename)"

        case "Write":
            let path = input["file_path"] as? String ?? "file"
            let filename = (path as NSString).lastPathComponent
            let content = input["content"] as? String ?? ""
            let preview = String(content.prefix(200))
            return "Writing \(filename): \(preview)"

        case "Edit":
            let path = input["file_path"] as? String ?? "file"
            let filename = (path as NSString).lastPathComponent
            let oldStr = input["old_string"] as? String ?? ""
            let newStr = input["new_string"] as? String ?? ""
            let oldPreview = String(oldStr.prefix(100))
            let newPreview = String(newStr.prefix(100))
            return "Editing \(filename) — replacing \"\(oldPreview)\" with \"\(newPreview)\""

        case "Bash":
            let cmd = input["command"] as? String ?? ""
            let desc = input["description"] as? String ?? ""
            if !desc.isEmpty {
                return "Running command: \(desc) (\(String(cmd.prefix(60))))"
            }
            return "Running: \(String(cmd.prefix(120)))"

        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String ?? ""
            return "Searching for '\(pattern)' in \((path as NSString).lastPathComponent)"

        case "Glob":
            let pattern = input["pattern"] as? String ?? ""
            return "Finding files matching '\(pattern)'"

        case "Agent":
            let desc = input["description"] as? String ?? ""
            let prompt = input["prompt"] as? String ?? ""
            return "Spawning agent: \(desc). Task: \(String(prompt.prefix(150)))"

        default:
            return "Using \(tool): \(String(describing: input).prefix(100))"
        }
    }
}
