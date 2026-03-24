import Foundation

// MARK: - DialogueLine

struct DialogueLine: Identifiable {
    let id: UUID
    let characterIndex: Int
    let text: String
    let timestamp: Date
    let isFiller: Bool  // true for filler/term explainer lines (shown in yellow in widget)

    init(characterIndex: Int, text: String, isFiller: Bool = false) {
        self.id = UUID()
        self.characterIndex = characterIndex
        self.text = text
        self.timestamp = Date()
        self.isFiller = isFiller
    }
}

// MARK: - Dialogue Parser

enum DialogueParser {

    /// Parse LLM response into dialogue lines.
    /// Expects format: "CharName: dialogue text" — one per line.
    /// Also handles markdown-formatted names like "**CharName**: text".
    /// `names` should be [char0.name, char1.name] from config.
    static func parse(_ responseText: String, names: [String]) -> [DialogueLine] {
        let rawLines = responseText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Build lowercase lookup: name -> character index
        // Include full names, first names, and common variants
        var nameToIndex: [String: Int] = [:]
        for (i, name) in names.enumerated() {
            nameToIndex[name.lowercased()] = i
            // Also map first name (e.g. "Bertram" from "Bertram Gilfoyle")
            if let first = name.split(separator: " ").first {
                nameToIndex[String(first).lowercased()] = i
            }
            // Map last name too (e.g. "Gilfoyle" from "Bertram Gilfoyle")
            if name.contains(" "), let last = name.split(separator: " ").last {
                nameToIndex[String(last).lowercased()] = i
            }
        }

        var results: [DialogueLine] = []

        for raw in rawLines {
            // Strip common LLM artifacts: numbering, bullets, markdown bold
            var cleaned = raw
            // Remove leading "1.", "2.", "- ", "* " etc.
            if let match = cleaned.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                cleaned = String(cleaned[match.upperBound...])
            }
            if cleaned.hasPrefix("- ") { cleaned = String(cleaned.dropFirst(2)) }
            if cleaned.hasPrefix("* ") { cleaned = String(cleaned.dropFirst(2)) }
            // Strip markdown bold from name: **Name**: -> Name:
            cleaned = cleaned.replacingOccurrences(of: "**", with: "")

            // Find name:text split — match known character names before the colon
            // This avoids false splits on colons within dialogue text
            var matchedIndex: Int?
            var textPart: String?

            for (knownName, idx) in nameToIndex {
                // Check if line starts with this character name followed by colon
                let prefix = knownName + ":"
                if cleaned.lowercased().hasPrefix(prefix) {
                    matchedIndex = idx
                    textPart = String(cleaned.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
                // Also try "Name :" with space before colon
                let prefixSpaced = knownName + " :"
                if cleaned.lowercased().hasPrefix(prefixSpaced) {
                    matchedIndex = idx
                    textPart = String(cleaned.dropFirst(prefixSpaced.count))
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            if let idx = matchedIndex, let text = textPart, !text.isEmpty {
                results.append(DialogueLine(characterIndex: idx, text: text))
            }
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
