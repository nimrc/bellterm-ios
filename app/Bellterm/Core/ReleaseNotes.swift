import Foundation

/// One release's notes, a line each.
struct Release: Equatable, Sendable {
    var version: String
    var notes: [String]
}

/// The changelog from `release-notes/<version>.<language>.txt`, bundled as a
/// folder: newest release first, in `language` where a release has it, else
/// English.
enum ReleaseNotes {
    static func load(language: String, bundle: Bundle = .main) -> [Release] {
        guard let folder = bundle.url(forResource: "release-notes", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var files: [String: String] = [:]
        for name in names {
            files[name] = try? String(contentsOf: folder.appending(path: name), encoding: .utf8)
        }
        return parse(files, language: language)
    }

    /// `files` maps file names to their text.
    static func parse(_ files: [String: String], language: String) -> [Release] {
        var byVersion: [String: [String: String]] = [:]
        for (name, text) in files where name.hasSuffix(".txt") {
            let stem = name.dropLast(4)
            guard let dot = stem.lastIndex(of: "."), dot != stem.startIndex else { continue }
            byVersion[String(stem[..<dot]), default: [:]][String(stem[stem.index(after: dot)...])] = text
        }
        return byVersion.compactMap { version, texts in
            guard let text = texts[language] ?? texts["en"] ?? texts.values.first else { return nil }
            let notes = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return notes.isEmpty ? nil : Release(version: version, notes: notes)
        }
        .sorted { newer($0.version, than: $1.version) }
    }

    /// Compares dotted versions part by part, so 1.10.0 follows 1.9.0.
    private static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (x.indices.contains(i) ? x[i] : 0) != (y.indices.contains(i) ? y[i] : 0) {
            return (x.indices.contains(i) ? x[i] : 0) > (y.indices.contains(i) ? y[i] : 0)
        }
        return false
    }
}
