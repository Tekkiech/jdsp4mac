import Foundation

/// Android SharedPreferences XML: `<map><boolean name="k" value="true"/><string name="k">v</string>…</map>`.
enum SharedPreferences {
    enum Value: Equatable {
        case bool(Bool), int(Int), long(Int64), float(Double), string(String), stringSet([String])

        var text: String {
            switch self {
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            case .long(let l): return String(l)
            case .float(let f): return String(f)
            case .string(let s): return s
            case .stringSet(let s): return s.joined(separator: ";")
            }
        }
    }

    static func parse(_ data: Data) throws -> [String: Value] {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ConversionError("SharedPreferences XML: \(parser.parserError?.localizedDescription ?? "parse error")")
        }
        return delegate.values
    }

    static func write(_ values: [(String, Value)]) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var xml = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n"
        for (key, value) in values {
            switch value {
            case .bool(let b): xml += "    <boolean name=\"\(esc(key))\" value=\"\(b)\" />\n"
            case .int(let i): xml += "    <int name=\"\(esc(key))\" value=\"\(i)\" />\n"
            case .long(let l): xml += "    <long name=\"\(esc(key))\" value=\"\(l)\" />\n"
            case .float(let f): xml += "    <float name=\"\(esc(key))\" value=\"\(Float(f))\" />\n"
            case .string(let s): xml += "    <string name=\"\(esc(key))\">\(esc(s))</string>\n"
            case .stringSet(let set):
                xml += "    <set name=\"\(esc(key))\">\n" + set.map { "        <string>\(esc($0))</string>\n" }.joined() + "    </set>\n"
            }
        }
        return Data((xml + "</map>\n").utf8)
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var values: [String: Value] = [:]
        private var stringKey: String?
        private var text = ""
        private var setKey: String?
        private var setItems: [String] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let name = attributes["name"]
            let value = attributes["value"] ?? ""
            switch element {
            case "boolean": if let name { values[name] = .bool(value == "true") }
            case "int": if let name { values[name] = .int(Int(value) ?? 0) }
            case "long": if let name { values[name] = .long(Int64(value) ?? 0) }
            case "float": if let name { values[name] = .float(Double(value) ?? 0) }
            case "string":
                stringKey = setKey == nil ? name : nil
                text = ""
            case "set":
                setKey = name
                setItems = []
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "string" {
                if let key = stringKey { values[key] = .string(text) } else if setKey != nil { setItems.append(text) }
                stringKey = nil
            } else if element == "set", let key = setKey {
                values[key] = .stringSet(setItems)
                setKey = nil
            }
        }
    }
}

public struct ConversionError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
