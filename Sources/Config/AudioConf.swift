import Foundation

/// A JDSP4Linux `audio.conf` / preset file, kept line by line so a load + save round-trips the
/// text exactly. Reading follows `ConfigIO::readLine` (JDSP4Linux src/config/ConfigIO.cpp):
/// lines that are empty or start with `#` or `[` are ignored, everything after the first `#` is a
/// comment, key and value are trimmed. Writing changed values follows `ConfigIO::writeFile`:
/// booleans `true`/`false`, floats `%.5f`, integers plain, strings as-is (no quotes).
public struct AudioConf: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case bool(Bool)
        case int(Int)
        case float(Double)
        case string(String)

        var serialized: String {
            switch self {
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            case .float(let f): return String(format: "%.5f", f)
            case .string(let s): return s
            }
        }
    }

    private enum Line: Equatable, Sendable {
        case other(String)  // blank, comment, section header, or no '='
        case entry(key: String, prefix: String, value: String, suffix: String)
    }

    private var lines: [Line] = []
    private var trailingNewline = true

    public init() {}

    public init(text: String) {
        guard !text.isEmpty else { return }
        trailingNewline = text.hasSuffix("\n")
        var parts = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { parts.removeLast() }
        lines = parts.map(Self.parseLine)
    }

    public init(contentsOf url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    private static func parseLine(_ line: String) -> Line {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["), line.contains("=") else {
            return .other(line)
        }
        // Everything after the first '#' is a comment (so values cannot contain '#', as on Linux).
        let hashIndex = line.firstIndex(of: "#") ?? line.endIndex
        let body = line[..<hashIndex]
        guard let eq = body.firstIndex(of: "=") else { return .other(line) }
        // Qt's trimmed() (used on Linux) also strips "\r", so CRLF files parse the same; the "\r"
        // stays in the line's suffix and is written back unchanged.
        let key = body[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
        let afterEq = body[body.index(after: eq)...]
        let leading = afterEq.prefix { $0 == " " || $0 == "\t" }
        let value = afterEq.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = afterEq.index(afterEq.startIndex, offsetBy: leading.count)
        let valueEnd = afterEq.index(valueStart, offsetBy: value.count)
        return .entry(key: key,
                      prefix: String(line[..<valueStart]),
                      value: value,
                      suffix: String(line[valueEnd...]))
    }

    /// Keys in file order (the last occurrence of a key wins on read, as with Linux's map).
    public var keys: [String] {
        var seen = Set<String>(), result: [String] = []
        for case .entry(let key, _, _, _) in lines where seen.insert(key).inserted { result.append(key) }
        return result
    }

    /// The raw value text (still quoted if the file quotes it).
    public func raw(_ key: String) -> String? {
        for case .entry(let k, _, let value, _) in lines.reversed() where k == key { return value }
        return nil
    }

    /// The value with surrounding double quotes removed (JDSP4Linux `chopDoubleQuotes`).
    public func string(_ key: String) -> String? {
        guard var v = raw(key) else { return nil }
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        return v
    }

    /// Sets a value. An existing line keeps its position and surrounding text; new keys are appended.
    public mutating func set(_ key: String, _ value: Value) {
        let text = value.serialized
        if let i = lines.lastIndex(where: { if case .entry(let k, _, _, _) = $0 { return k == key } else { return false } }),
           case .entry(_, let prefix, _, let suffix) = lines[i] {
            lines[i] = .entry(key: key, prefix: prefix, value: text, suffix: suffix)
        } else {
            lines.append(.entry(key: key, prefix: key + "=", value: text, suffix: ""))
        }
    }

    public var text: String {
        let body = lines.map { line -> String in
            switch line {
            case .other(let s): return s
            case .entry(_, let prefix, let value, let suffix): return prefix + value + suffix
            }
        }.joined(separator: "\n")
        return trailingNewline && !lines.isEmpty ? body + "\n" : body
    }
}
