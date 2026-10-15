import Foundation
import JavaScriptCore

/// A module put together from files picked on the device: a manifest (.json), its script (.js),
/// or both.
///
/// - Both: the manifest, with the picked script as its script.
/// - A manifest alone: its script is downloaded from the manifest's `scriptUrl`, as from a link.
/// - A script alone: a manifest is made up for it, named after the file.
enum ModuleFileImport {
    struct File: Equatable {
        var name: String
        var data: Data

        var isManifest: Bool { name.lowercased().hasSuffix(".json") }
        var isScript: Bool { name.lowercased().hasSuffix(".js") }
        var baseName: String { (name as NSString).deletingPathExtension }
    }

    enum Failure: LocalizedError, Equatable {
        case nothingPicked
        case tooMany
        case unreadableScript(String)
        case notAModule(String, String)

        var errorDescription: String? {
            switch self {
            case .nothingPicked:
                return "Pick a module's .json file, its .js file, or both."
            case .tooMany:
                return "Pick one .json file and one .js file at most."
            case .unreadableScript(let name):
                return "\(name) isn't a text file."
            case .notAModule(let name, let reason):
                return "\(name) isn't a module manifest: \(reason)"
            }
        }
    }

    /// What `build` made, and whether the script still has to be downloaded.
    struct Result {
        var module: ModuleDefinition
        var needsScriptDownload: Bool
    }

    /// The scheme of a made-up `scriptUrl`, which is also the module's id.
    static let scriptScheme = "shirox-file"

    static func build(from files: [File], makeID: () -> String = { UUID().uuidString }) throws -> Result {
        let manifests = files.filter(\.isManifest)
        let scripts = files.filter(\.isScript)
        guard !manifests.isEmpty || !scripts.isEmpty else { throw Failure.nothingPicked }
        guard manifests.count <= 1, scripts.count <= 1 else { throw Failure.tooMany }

        var script: String?
        if let file = scripts.first {
            guard let text = String(data: file.data, encoding: .utf8) ?? String(data: file.data, encoding: .isoLatin1)
            else { throw Failure.unreadableScript(file.name) }
            script = text
        }

        if let manifest = manifests.first {
            var module: ModuleDefinition
            do {
                module = try JSONDecoder().decode(ModuleDefinition.self, from: manifest.data)
            } catch {
                throw Failure.notAModule(manifest.name, reason(error))
            }
            module.jsonUrl = nil
            module.fromFile = true
            module.scriptEdited = nil
            if let script {
                module.scriptContent = script
                return Result(module: module, needsScriptDownload: false)
            }
            module.scriptContent = nil
            return Result(module: module, needsScriptDownload: true)
        }

        // A script alone.
        let file = scripts[0]
        let text = script ?? ""
        let object: [String: Any] = [
            "sourceName": file.baseName.isEmpty ? "Module" : file.baseName,
            "version": "1.0.0",
            "scriptUrl": "\(scriptScheme)://\(makeID())/\(file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "module.js")",
            "type": looksLikeManga(text) ? "manga" : "anime",
            "asyncJS": text.contains("async "),
        ]
        var module = try JSONDecoder().decode(
            ModuleDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        module.fromFile = true
        module.scriptContent = text
        return Result(module: module, needsScriptDownload: false)
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

    private static func reason(_ error: Error) -> String {
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
