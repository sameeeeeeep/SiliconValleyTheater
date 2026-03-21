import Foundation

// MARK: - DialogueLine

struct DialogueLine: Identifiable {
    let id: UUID
    let characterIndex: Int
    let text: String
    let timestamp: Date

    init(characterIndex: Int, text: String) {
        self.id = UUID()
        self.characterIndex = characterIndex
        self.text = text
        self.timestamp = Date()
    }
}

// MARK: - Dialogue Parser

enum DialogueParser {

    /// Parse Ollama response into dialogue lines.
    /// Expects format: "CharName: dialogue text" — one per line.
    /// `names` should be [char0.name, char1.name] from config.
    static func parse(_ responseText: String, names: [String]) -> [DialogueLine] {
        let rawLines = responseText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Build lowercase lookup: name -> character index
        var nameToIndex: [String: Int] = [:]
        for (i, name) in names.enumerated() {
            nameToIndex[name.lowercased()] = i
            // Also map first name (e.g. "Bertram" from "Bertram Gilfoyle")
            if let first = name.split(separator: " ").first {
                nameToIndex[String(first).lowercased()] = i
            }
        }

        var results: [DialogueLine] = []

        for raw in rawLines {
            // Match "Name: text" pattern — colon may have spaces around it
            guard let colonRange = raw.range(of: ":") else { continue }

            let namePart = raw[raw.startIndex..<colonRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let textPart = raw[colonRange.upperBound...]
                .trimmingCharacters(in: .whitespaces)

            guard !textPart.isEmpty else { continue }

            // Try to match name to a character
            if let idx = nameToIndex[namePart] {
                results.append(DialogueLine(characterIndex: idx, text: String(textPart)))
            }
            // If name doesn't match any character, skip the line (it's probably preamble)
        }

        // If we got nothing from name matching, fall back to alternating assignment
        if results.isEmpty {
            return fallbackParse(rawLines)
        }

        return results
    }

    /// Fallback: treat non-empty lines as alternating speakers.
    private static func fallbackParse(_ lines: [String]) -> [DialogueLine] {
        lines.enumerated().map { index, line in
            DialogueLine(characterIndex: index % 2, text: line)
        }
    }
}
