import Foundation
import JavaScriptCore

/// Helpers for modules whose files are on the device: reading a manifest picked in
/// `ModuleImportView`, checking a script, and writing a module out as files to share.
enum ModuleFileImport {
    enum Failure: LocalizedError, Equatable {
        case notAModule(String, String)

        var errorDescription: String? {
            switch self {
            case .notAModule(let name, let reason):
                return "\(name) isn't a module manifest: \(reason)"
            }
        }
    }

    /// The scheme of a made-up `scriptUrl`, which is also the module's id.
    static let scriptScheme = "shirox-file"

    /// The made-up script address, and so the id, of a module whose script came from a file.
    static func fileScriptURL(named fileName: String) -> String {
        "\(scriptScheme)://\(UUID().uuidString)/\(fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "module.js")"
    }

    /// A module as its two files, `<name>.json` and `<name>.js`, in a fresh temporary folder, to
    /// share. The manifest keeps the module's icon inside it, so it travels with the files.
    static func exportFiles(for module: ModuleDefinition) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("module-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = module.sourceName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined()
        let base = safe.trimmingCharacters(in: .whitespaces).isEmpty ? "module" : safe
        let jsName = "\(base).js"
        var manifest = module
        manifest.scriptContent = nil
        manifest.jsonUrl = nil
        manifest.fromFile = nil
        manifest.scriptEdited = nil
        // A file module's address means nothing elsewhere: name the script file instead.
        let scriptUrl = module.scriptUrl.hasPrefix("\(scriptScheme)://") ? jsName : module.scriptUrl
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any] ?? [:]
        object["scriptUrl"] = scriptUrl
        let json = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let jsonURL = folder.appendingPathComponent("\(base).json")
        let jsURL = folder.appendingPathComponent(jsName)
        try json.write(to: jsonURL)
        try Data((module.scriptContent ?? "").utf8).write(to: jsURL)
        return [jsonURL, jsURL]
    }

    /// Manga modules give chapters and pages rather than episodes and streams.
    static func looksLikeManga(_ script: String) -> Bool {
        let manga = script.contains("extractChapters") || script.contains("extractImages")
        let video = script.contains("extractEpisodes") || script.contains("extractStreamUrl")
        return manga && !video
    }

    /// The first syntax error in a script, as JavaScriptCore reports it, or nil when it parses.
    /// Nothing is run.
    static func syntaxError(in script: String) -> String? {
        guard let context = JSContext() else { return nil }
        let source = JSStringCreateWithCFString(script as CFString)
        defer { JSStringRelease(source) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context.jsGlobalContextRef, source, nil, 1, &exception),
              let exception else { return nil }
        let value = JSValue(jsValueRef: exception, in: context)
        let message = value?.toString() ?? "Syntax error"
        if let line = value?.objectForKeyedSubscript("line"), line.isNumber {
            return "\(message) (line \(line.toInt32()))"
        }
        return message
    }

    static func reason(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return "it has no \"\(key.stringValue)\"."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "it isn't a JSON object." : "\"\(path)\" has the wrong type."
        case DecodingError.dataCorrupted:
            return "it isn't valid JSON."
        default:
            return error.localizedDescription
        }
    }
}
