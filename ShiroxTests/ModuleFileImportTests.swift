import XCTest
@testable import Shirox

final class ModuleFileImportTests: XCTestCase {
    private let script = "async function searchResults(q) { return '[]' }\nasync function extractStreamUrl(u) { return u }"

    private func module(scriptUrl: String) throws -> ModuleDefinition {
        var module = try JSONDecoder().decode(ModuleDefinition.self, from: Data("""
        {"sourceName":"Pahe / Mirror","version":"2.1","scriptUrl":"\(scriptUrl)","type":"anime",
         "author":{"name":"someone"},"iconUrl":"https://example.com/i.png"}
        """.utf8))
        module.scriptContent = script
        module.iconData = Data([1, 2, 3]).base64EncodedString()
        module.fromFile = true
        return module
    }

    func testMangaScriptsAreTold() {
        XCTAssertTrue(ModuleFileImport.looksLikeManga("async function extractChapters(u) {}\nasync function extractImages(u) {}"))
        XCTAssertFalse(ModuleFileImport.looksLikeManga(script))
    }

    func testSyntaxCheckDoesNotRunTheScript() {
        XCTAssertNil(ModuleFileImport.syntaxError(in: "throw new Error('ran')"))
        XCTAssertNil(ModuleFileImport.syntaxError(in: script))
        let error = ModuleFileImport.syntaxError(in: "function a( {\n}")
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("line") == true, error ?? "")
    }

    func testAFileModuleIsSharedAsAManifestAndItsScript() throws {
        let urls = try ModuleFileImport.exportFiles(for: module(scriptUrl: ModuleFileImport.fileScriptURL(named: "pahe.js")))
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Pahe  Mirror.json", "Pahe  Mirror.js"])
        XCTAssertEqual(try String(contentsOf: urls[1], encoding: .utf8), script)
        let shared = try JSONDecoder().decode(ModuleDefinition.self, from: Data(contentsOf: urls[0]))
        XCTAssertEqual(shared.sourceName, "Pahe / Mirror")
        XCTAssertEqual(shared.scriptUrl, "Pahe  Mirror.js", "a device-only address isn't shared")
        XCTAssertEqual(shared.author?.name, "someone")
        XCTAssertNotNil(shared.iconData, "the icon travels inside the manifest")
        XCTAssertNil(shared.scriptContent)
        XCTAssertFalse(shared.isFromFile)
    }

    func testALinkedModuleKeepsItsScriptAddress() throws {
        let urls = try ModuleFileImport.exportFiles(for: module(scriptUrl: "https://example.com/pahe.js"))
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let shared = try JSONDecoder().decode(ModuleDefinition.self, from: Data(contentsOf: urls[0]))
        XCTAssertEqual(shared.scriptUrl, "https://example.com/pahe.js")
    }

    func testFlagsSurviveEncoding() throws {
        var module = try module(scriptUrl: ModuleFileImport.fileScriptURL(named: "x.js"))
        module.scriptEdited = true
        let decoded = try JSONDecoder().decode(ModuleDefinition.self, from: JSONEncoder().encode(module))
        XCTAssertTrue(decoded.isFromFile)
        XCTAssertTrue(decoded.isScriptEdited)
        XCTAssertEqual(decoded.scriptContent, script)
    }
}
