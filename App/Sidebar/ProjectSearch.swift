import Foundation

/// What the Search view looks for: the query, its three toggles and the include/exclude globs.
struct SearchQuery: Equatable {
    var text = ""
    var isRegex = false
    var matchCase = false
    var wholeWord = false
    var include = ""
    var exclude = ""

    /// Throws `SearchError.invalidRegex` with the reason when the pattern doesn't compile.
    func regex() throws -> NSRegularExpression {
        var pattern = isRegex ? text : NSRegularExpression.escapedPattern(for: text)
        if wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !matchCase { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw SearchError.invalidRegex
        }
    }
}

enum SearchError: LocalizedError {
    case invalidRegex
    var errorDescription: String? { "Invalid regular expression." }
}

/// One occurrence. Ranges are UTF-16, which is also what the editor's JavaScript uses.
struct SearchMatch {
    let line: Int            // 1-based
    let column: Int          // offset of the match in its line
    let range: NSRange       // in the whole file
    let lineText: String     // the line, without its line break
    let matchedText: String
}

struct SearchFileResult {
    let path: String
    var matches: [SearchMatch]
}

struct SearchOutcome {
    var files: [SearchFileResult] = []
    /// Stopped at `ProjectSearch.maxResults`, as VS Code does.
    var limitHit = false
    var matchCount: Int { files.reduce(0) { $0 + $1.matches.count } }
}

/// Set from the main thread to stop a search that's running in the background.
final class SearchCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum ProjectSearch {
    static let maxResults = 20_000
    static let maxFileSize = 4 * 1024 * 1024

    /// Searches `paths` (relative to `root`). Binary, non-UTF-8 and very large files are skipped.
    static func run(_ query: SearchQuery, root: URL, paths: [String], cancellation: SearchCancellation) throws -> SearchOutcome {
        let regex = try query.regex()
        let include = GlobSet(query.include)
        let exclude = GlobSet(query.exclude)
        var outcome = SearchOutcome()
        var total = 0

        for path in paths {
            if cancellation.isCancelled || outcome.limitHit { break }
            if !include.isEmpty && !include.matches(path) { continue }
            if exclude.matches(path) { continue }
            let url = root.appendingPathComponent(path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
                  let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }

            let ns = text as NSString
            var matches: [SearchMatch] = []
            var lineNumber = 1
            var scanned = 0
            regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, stop in
                guard let range = result?.range, range.length > 0 else { return }
                if total >= maxResults {
                    outcome.limitHit = true
                    stop.pointee = true
                    return
                }
                // Count line breaks since the last match (\n, \r\n and a lone \r, as the editor does).
                var i = scanned
                while i < range.location {
                    let c = ns.character(at: i)
                    if c == 0x0A || (c == 0x0D && (i + 1 >= ns.length || ns.character(at: i + 1) != 0x0A)) { lineNumber += 1 }
                    i += 1
                }
                scanned = range.location
                var start = 0, end = 0, contentsEnd = 0
                ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: range.location, length: 0))
                matches.append(SearchMatch(line: lineNumber, column: range.location - start, range: range,
                                           lineText: ns.substring(with: NSRange(location: start, length: contentsEnd - start)),
                                           matchedText: ns.substring(with: range)))
                total += 1
            }
            if !matches.isEmpty { outcome.files.append(SearchFileResult(path: path, matches: matches)) }
        }
        return outcome
    }

    /// The text that replaces `match`. In regex mode `$1` refers to groups and `\n`/`\t` are
    /// a newline and tab. With `preserveCase`, ALL CAPS, lower case and Capitalized matches are kept that way.
    static func replacement(for match: SearchMatch, in text: String, regex: NSRegularExpression,
                            query: SearchQuery, replaceText: String, preserveCase: Bool) -> String {
        var result = replaceText
        if query.isRegex,
           let found = regex.firstMatch(in: text, options: [.withTransparentBounds], range: match.range),
           found.range == match.range {
            result = regex.replacementString(for: found, in: text, offset: 0, template: regexTemplate(replaceText))
        }
        return preserveCase ? preservingCase(result, like: match.matchedText) : result
    }

    /// The replacement for the editor-style preview, worked out within the match's line.
    static func previewReplacement(for match: SearchMatch, regex: NSRegularExpression, query: SearchQuery,
                                   replaceText: String, preserveCase: Bool) -> String {
        let local = SearchMatch(line: match.line, column: match.column,
                                range: NSRange(location: match.column, length: match.matchedText.utf16.count),
                                lineText: match.lineText, matchedText: match.matchedText)
        return replacement(for: local, in: match.lineText, regex: regex, query: query,
                           replaceText: replaceText, preserveCase: preserveCase)
    }

    /// Replaces `matches` in one file, last first so earlier ranges stay valid. A match whose text
    /// changed since the search is left alone. Returns how many were replaced.
    static func replace(_ matches: [SearchMatch], in url: URL, query: SearchQuery,
                        replaceText: String, preserveCase: Bool) throws -> Int {
        let original = try String(contentsOf: url, encoding: .utf8)
        let source = original as NSString
        let text = NSMutableString(string: original)
        let regex = try query.regex()
        var count = 0
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(match.range) <= source.length, source.substring(with: match.range) == match.matchedText else { continue }
            let replacement = replacement(for: match, in: original, regex: regex, query: query,
                                          replaceText: replaceText, preserveCase: preserveCase)
            text.replaceCharacters(in: match.range, with: replacement)
            count += 1
        }
        if count > 0 { try (text as String).write(to: url, atomically: true, encoding: .utf8) }
        return count
    }

    /// VS Code's regex replace strings: `\n` and `\t` are characters; `$1` and `\\` work as in NSRegularExpression.
    private static func regexTemplate(_ text: String) -> String {
        var out = ""
        var chars = text.makeIterator()
        while let c = chars.next() {
            guard c == "\\" else { out.append(c); continue }
            switch chars.next() {
            case "n"?: out.append("\n")
            case "t"?: out.append("\t")
            case .some(let next): out.append("\\"); out.append(next)
            case .none: out.append("\\\\")
            }
        }
        return out
    }

    static func preservingCase(_ replacement: String, like matched: String) -> String {
        guard !matched.isEmpty, !replacement.isEmpty else { return replacement }
        if matched == matched.uppercased() && matched != matched.lowercased() { return replacement.uppercased() }
        if matched == matched.lowercased() && matched != matched.uppercased() { return replacement.lowercased() }
        if let first = matched.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}

/// Comma-separated glob patterns, as in the "files to include/exclude" boxes.
/// A pattern without a slash matches a file or folder name anywhere (`*.lua`, `libs`);
/// `**` crosses folders and `{a,b}` lists alternatives.
struct GlobSet {
    private let regexes: [NSRegularExpression]

    init(_ patterns: String) {
        regexes = Self.split(patterns).compactMap { raw in
            var glob = raw.trimmingCharacters(in: .whitespaces)
            while glob.hasPrefix("./") { glob.removeFirst(2) }
            while glob.hasPrefix("/") { glob.removeFirst() }
            while glob.hasSuffix("/") { glob.removeLast() }
            guard !glob.isEmpty else { return nil }
            let body = Self.regexSource(glob)
            let source = glob.contains("/") ? "^\(body)(?:/.*)?$" : "^(?:.*/)?\(body)(?:/.*)?$"
            return try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
        }
    }

    var isEmpty: Bool { regexes.isEmpty }

    func matches(_ path: String) -> Bool {
        let range = NSRange(location: 0, length: (path as NSString).length)
        return regexes.contains { $0.firstMatch(in: path, options: [], range: range) != nil }
    }

    /// Splits on commas that aren't inside `{...}`.
    private static func split(_ patterns: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for c in patterns {
            if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
            if c == "," && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    private static func regexSource(_ glob: String) -> String {
        let chars = Array(glob)
        var out = ""
        var braces = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    i += 1
                    if i + 1 < chars.count && chars[i + 1] == "/" {
                        i += 1
                        out += "(?:.*/)?"
                    } else {
                        out += ".*"
                    }
                } else {
                    out += "[^/]*"
                }
            case "?":
                out += "[^/]"
            case "{":
                braces += 1
                out += "(?:"
            case "}" where braces > 0:
                braces -= 1
                out += ")"
            case "," where braces > 0:
                out += "|"
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]") {
                    var set = String(chars[(i + 1)..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close
                } else {
                    out += "\\["
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        out += String(repeating: ")", count: braces)
        return out
    }
}
