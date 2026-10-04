import XCTest
@testable import Shirox

/// Moving an earlier Mac build's downloads out of `~/Documents`.
final class AppDirectoriesTests: XCTestCase {
    private var root: URL!
    private var old: URL { root.appendingPathComponent("Documents") }
    private var base: URL { root.appendingPathComponent("Shirox") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("app-directories-\(UUID().uuidString)")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func make(_ name: String, folder: Bool = false) throws {
        let url = old.appendingPathComponent(name)
        if folder {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("episode.mp4"))
        } else {
            try Data("[]".utf8).write(to: url)
        }
    }

    private func exists(_ url: URL, _ name: String) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent(name).path)
    }

    func testShiroxsDownloadsMoveWithTheirManifests() throws {
        try make("Downloads", folder: true)
        try make("downloads_manifest.json")
        try make("MangaDownloads", folder: true)
        try make("manga_downloads_manifest.json")
        AppDirectories.moveDownloads(from: old, to: base)
        for name in ["Downloads", "downloads_manifest.json", "MangaDownloads", "manga_downloads_manifest.json"] {
            XCTAssertTrue(exists(base, name), name)
            XCTAssertFalse(exists(old, name), name)
        }
        XCTAssertTrue(exists(base, "Downloads/episode.mp4"))
    }

    /// A build moved the user's own `~/Documents/Downloads` out of sight on first launch.
    func testADownloadsFolderWithNoManifestIsLeftWhereItIs() throws {
        try make("Downloads", folder: true)
        AppDirectories.moveDownloads(from: old, to: base)
        XCTAssertTrue(exists(old, "Downloads/episode.mp4"))
        XCTAssertFalse(exists(base, "Downloads"))
    }

    func testWhatsAlreadyThereIsntReplaced() throws {
        try make("downloads_manifest.json")
        try Data("new".utf8).write(to: base.appendingPathComponent("downloads_manifest.json"))
        AppDirectories.moveDownloads(from: old, to: base)
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("downloads_manifest.json"), encoding: .utf8), "new")
        XCTAssertTrue(exists(old, "downloads_manifest.json"))
    }
}
