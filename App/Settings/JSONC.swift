import Foundation

/// JSON with comments and trailing commas, as VS Code's settings.json and keybindings.json are
/// written.
enum JSONC {
    /// Plain JSON: comments (// and /* */) removed, and commas before ] or } dropped. Text in
    /// strings is left alone.
    static func strip(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var noComments = String.UnicodeScalarView()
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                noComments.append(c)
                if c == "\\", i + 1 < chars.count { noComments.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; noComments.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            noComments.append(c)
            i += 1
        }
        // Trailing commas, outside strings.
        let plain = Array(noComments)
        var out = String.UnicodeScalarView()
        inString = false
        i = 0
        while i < plain.count {
            let c = plain[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < plain.count { out.append(plain[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var j = i + 1
                while j < plain.count && CharacterSet.whitespacesAndNewlines.contains(plain[j]) { j += 1 }
                if j < plain.count && (plain[j] == "]" || plain[j] == "}") { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// The value in `text` (an empty file is an empty object).
    static func parse(_ text: String) throws -> Any {
        let json = strip(text)
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [String: Any]() }
        return try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    /// `text`'s object, or nil if it isn't one (or doesn't parse).
    static func object(_ text: String) -> [String: Any]? {
        (try? parse(text)) as? [String: Any]
    }
}
