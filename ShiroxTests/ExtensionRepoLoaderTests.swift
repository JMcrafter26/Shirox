import XCTest
@testable import Shirox

final class ExtensionRepoLoaderTests: XCTestCase {
    func testModuleRoundTripsExtensionInfo() throws {
        let json = #"{"sourceName":"A","version":"1","scriptUrl":"https://x/a.js","type":"anime","#
            + #""ext":{"kind":"nuvio","repoUrl":"https://x/manifest.json","key":"a","config":"{}"}}"#
        let module = try JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(module.ext?.kind, .nuvio)
        let again = try JSONDecoder().decode(ModuleDefinition.self, from: JSONEncoder().encode(module))
        XCTAssertEqual(again.ext, module.ext)
        XCTAssertEqual(ExtensionKind.skystream.badge, "SkyStream")
    }
}
