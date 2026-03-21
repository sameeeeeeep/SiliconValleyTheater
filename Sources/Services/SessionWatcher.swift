import Foundation

// MARK: - SessionWatcher

/// Watches Claude Code JSONL session files for new events.
/// Monitors ~/.claude/projects/ for the most recently active session.
@Observable
final class SessionWatcher {

    private(set) var isWatching = false
    private(set) var currentSessionFile: String?
    private(set) var eventCount = 0

    private var fileHandle: FileHandle?
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceTimer?
    private var continuation: AsyncStream<SessionEvent>.Continuation?
    private let queue = DispatchQueue(label: "com.siliconvalley.session-watcher", qos: .utility)

    private let claudeProjectsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }()

    /// Represents a discovered Claude Code session.
    struct SessionInfo: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let projectName: String
        let sessionId: String
        let lastModified: Date
        let sizeKB: Int

        var displayName: String {
            let clean = projectName
                .replacingOccurrences(of: "-Users-sameeprehlan-", with: "")
                .replacingOccurrences(of: "-", with: "/")
            return clean.isEmpty ? sessionId.prefix(8).description : clean
        }
    }

    /// Currently pinned session (nil = auto-follow latest)
    private(set) var pinnedSession: String?

    /// All discovered sessions
    private(set) var availableSessions: [SessionInfo] = []

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Pin to a specific session file path, or nil to auto-follow latest.
    func pinSession(_ path: String?) {
        pinnedSession = path
        if let path = path {
            debugLog("[Watcher] Pinned to session: \(path.suffix(50))")
            tailFile(at: path)
        } else {
            debugLog("[Watcher] Unpinned — auto-following latest")
            if let latest = findLatestSessionFile() {
                tailFile(at: latest)
            }
        }
    }

    /// Refresh the list of available sessions.
    func refreshSessions() {
        availableSessions = findAllSessions()
    }

    /// Start watching and return an async stream of session events.
    func watch() -> AsyncStream<SessionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.startWatching()

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        isWatching = false
        dispatchSource?.cancel()
        dispatchSource = nil
        directorySource?.cancel()
        directorySource = nil
        fileHandle?.closeFile()
        fileHandle = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internal

    private func startWatching() {
        guard !isWatching else { return }
        isWatching = true

        debugLog("[Watcher] Projects dir: \(claudeProjectsDir.path)")

        // Discover all sessions
        availableSessions = findAllSessions()
        debugLog("[Watcher] Found \(availableSessions.count) sessions")

        // Watch the projects directory for new/changed files
        watchProjectsDirectory()

        // Tail pinned session or latest
        if let pinned = pinnedSession {
            debugLog("[Watcher] Resuming pinned session: \(pinned.suffix(50))")
            tailFile(at: pinned)
        } else if let latest = findLatestSessionFile() {
            debugLog("[Watcher] Found latest session: \(latest)")
            tailFile(at: latest)
        } else {
            debugLog("[Watcher] No JSONL files found in \(claudeProjectsDir.path)")
        }
    }

    /// Poll for new session files periodically (kqueue on parent dir doesn't detect
    /// file content changes in subdirectories).
    private func watchProjectsDirectory() {
        guard FileManager.default.fileExists(atPath: claudeProjectsDir.path) else {
            debugLog("[Watcher] Projects dir does not exist: \(claudeProjectsDir.path)")
            return
        }

        // Use a timer-based poll every 5 seconds to pick up new sessions
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 5, repeating: 5.0)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Refresh session list
            self.availableSessions = self.findAllSessions()
            // Only auto-switch if not pinned
            if self.pinnedSession == nil,
               let latest = self.findLatestSessionFile(),
               latest != self.currentSessionFile {
                debugLog("[Watcher] New session detected: \(latest)")
                self.tailFile(at: latest)
            }
        }
        source.resume()
        directorySource = source
    }

    /// Find all active session files across all project subdirectories, sorted by recent first.
    private func findAllSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-86400 * 7)  // last 7 days
        var sessions: [SessionInfo] = []

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            guard !url.path.contains("/subagents/") else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int,
                  modDate > cutoff
            else { continue }

            let sessionId = url.deletingPathExtension().lastPathComponent
            let projectName = url.deletingLastPathComponent().lastPathComponent

            sessions.append(SessionInfo(
                path: url.path,
                projectName: projectName,
                sessionId: sessionId,
                lastModified: modDate,
                sizeKB: size / 1024
            ))
        }

        return sessions.sorted { $0.lastModified > $1.lastModified }
    }

    /// Find the most recently modified .jsonl file across all project subdirectories (recursive).
    private func findLatestSessionFile() -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var latestPath: String?
        var latestDate = Date.distantPast

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            // Skip subagent files — only watch main session files
            guard !url.path.contains("/subagents/") else { continue }

            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modDate = attrs[.modificationDate] as? Date
            else { continue }

            if modDate > latestDate {
                latestDate = modDate
                latestPath = url.path
            }
        }

        return latestPath
    }

    /// Start tailing a specific JSONL file from the current end.
    private func tailFile(at path: String) {
        // Clean up previous file watch
        dispatchSource?.cancel()
        dispatchSource = nil
        fileHandle?.closeFile()
        fileHandle = nil

        currentSessionFile = path

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        self.fileHandle = handle

        // Seek to end — we only want new events
        handle.seekToEndOfFile()

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.readNewLines()
        }

        source.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }

        source.resume()
        dispatchSource = source
    }

    /// Read newly appended lines and parse them into events.
    private func readNewLines() {
        guard let handle = fileHandle else { return }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else { return }

        debugLog("[Watcher] Read \(data.count) bytes, parsing lines...")
        let lines = text.components(separatedBy: .newlines)
        var parsed = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let event = SessionEventParser.parse(line: trimmed) {
                parsed += 1
                eventCount += 1
                continuation?.yield(event)
            }
        }
        debugLog("[Watcher] Parsed \(parsed) events from \(lines.count) lines")
    }
}
