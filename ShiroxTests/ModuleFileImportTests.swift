import XCTest
@testable import Shirox

final class ModuleFileImportTests: XCTestCase {
    private let manifest = Data("""
    {"sourceName":"Pahe","version":"2.1","scriptUrl":"https://example.com/pahe.js","type":"anime","baseUrl":"https://example.com"}
    """.utf8)
    private let script = "async function searchResults(q) { return '[]' }\nasync function extractStreamUrl(u) { return u }"

    private func file(_ name: String, _ text: String) -> ModuleFileImport.File {
        .init(name: name, data: Data(text.utf8))
    }

    func testManifestAndScriptTogether() throws {
        let result = try ModuleFileImport.build(from: [
            .init(name: "pahe.json", data: manifest), file("pahe.js", script),
        ])
        XCTAssertFalse(result.needsScriptDownload)
        XCTAssertEqual(result.module.sourceName, "Pahe")
        XCTAssertEqual(result.module.id, "https://example.com/pahe.js")
        XCTAssertEqual(result.module.scriptContent, script)
        XCTAssertTrue(result.module.isFromFile)
        XCTAssertNil(result.module.jsonUrl)
    }

    func testManifestAloneDownloadsItsScript() throws {
        let result = try ModuleFileImport.build(from: [.init(name: "PAHE.JSON", data: manifest)])
        XCTAssertTrue(result.needsScriptDownload)
        XCTAssertNil(result.module.scriptContent)
    }

    func testScriptAloneGetsAManifestNamedAfterTheFile() throws {
        let result = try ModuleFileImport.build(from: [file("My Source.js", script)], makeID: { "abc" })
        XCTAssertEqual(result.module.sourceName, "My Source")
        XCTAssertEqual(result.module.scriptUrl, "shirox-file://abc/My%20Source.js")
        XCTAssertEqual(result.module.type, "anime")
        XCTAssertEqual(result.module.scriptContent, script)
        XCTAssertFalse(result.needsScriptDownload)
    }

    func testMangaScriptIsAMangaModule() throws {
        let manga = "async function extractChapters(u) {}\nasync function extractImages(u) {}"
        XCTAssertEqual(try ModuleFileImport.build(from: [file("m.js", manga)]).module.type, "manga")
    }

    func testRejectsOtherFilesAndPairs() {
        XCTAssertThrowsError(try ModuleFileImport.build(from: [file("a.txt", "x")])) {
            XCTAssertEqual($0 as? ModuleFileImport.Failure, .nothingPicked)
        }
        XCTAssertThrowsError(try ModuleFileImport.build(from: [file("a.js", "x"), file("b.js", "y")])) {
            XCTAssertEqual($0 as? ModuleFileImport.Failure, .tooMany)
        }
        XCTAssertThrowsError(try ModuleFileImport.build(from: [file("a.json", "{\"sourceName\":\"x\"}")])) {
            guard case .notAModule(let name, _)? = $0 as? ModuleFileImport.Failure else { return XCTFail("\($0)") }
            XCTAssertEqual(name, "a.json")
        }
    }

    func testSyntaxCheckDoesNotRunTheScript() {
        XCTAssertNil(ModuleFileImport.syntaxError(in: "throw new Error('ran')"))
        XCTAssertNil(ModuleFileImport.syntaxError(in: script))
        let error = ModuleFileImport.syntaxError(in: "function a( {\n}")
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("line") == true, error ?? "")
    }

    func testFlagsSurviveEncoding() throws {
        var module = try ModuleFileImport.build(from: [file("x.js", script)]).module
        module.scriptEdited = true
        let decoded = try JSONDecoder().decode(ModuleDefinition.self, from: JSONEncoder().encode(module))
        XCTAssertTrue(decoded.isFromFile)
        XCTAssertTrue(decoded.isScriptEdited)
        XCTAssertEqual(decoded.scriptContent, script)
    }
}
