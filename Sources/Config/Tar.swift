import Foundation

/// Minimal ustar reader/writer: regular files only, names up to 100 bytes. Enough for
/// RootlessJamesDSP preset archives (written by jtar's TarOutputStream).
enum Tar {
    struct Entry: Equatable {
        var name: String
        var data: Data
    }

    static func read(_ archive: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        let bytes = [UInt8](archive)
        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) { break }  // end-of-archive marker
            let name = cString(header[0..<100])
            let prefix = cString(header[345..<500])
            guard let size = Int(cString(header[124..<136]).trimmingCharacters(in: .whitespaces), radix: 8) else {
                throw ConversionError("tar: bad size field for \(name)")
            }
            let type = header[156]
            let start = offset + 512
            guard start + size <= bytes.count else { throw ConversionError("tar: truncated entry \(name)") }
            if type == 0 || type == UInt8(ascii: "0") {
                let full = prefix.isEmpty ? name : prefix + "/" + name
                entries.append(Entry(name: full, data: Data(bytes[start..<start + size])))
            }
            offset = start + (size + 511) / 512 * 512
        }
        return entries
    }

    static func write(_ entries: [Entry], mtime: Date = Date()) -> Data {
        var out = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int, length: Int) {
                let utf8 = Array(text.utf8.prefix(length))
                header.replaceSubrange(offset..<offset + utf8.count, with: utf8)
            }
            func octal(_ value: Int, at offset: Int, length: Int) {
                put(String(format: "%0\(length - 1)o", value), at: offset, length: length - 1)
            }
            put(entry.name, at: 0, length: 100)
            octal(0o644, at: 100, length: 8)
            octal(0, at: 108, length: 8)
            octal(0, at: 116, length: 8)
            octal(entry.data.count, at: 124, length: 12)
            octal(Int(mtime.timeIntervalSince1970), at: 136, length: 12)
            header[156] = UInt8(ascii: "0")
            put("ustar", at: 257, length: 6)
            put("00", at: 263, length: 2)
            // Checksum: sum of the header with the checksum field read as spaces.
            for i in 148..<156 { header[i] = UInt8(ascii: " ") }
            let sum = header.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), at: 148, length: 6)
            header[154] = 0
            header[155] = UInt8(ascii: " ")
            out.append(contentsOf: header)
            out.append(entry.data)
            let pad = (512 - entry.data.count % 512) % 512
            out.append(contentsOf: [UInt8](repeating: 0, count: pad))
        }
        out.append(contentsOf: [UInt8](repeating: 0, count: 1024))
        return out
    }

    private static func cString(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
