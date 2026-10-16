import XCTest
@testable import Shirox

final class ZipReaderTests: XCTestCase {
    // printf 'hello' > a.txt && zip -0 -X s.zip a.txt && base64 -i s.zip
    let stored = "UEsDBAoAAAAAAG+2T12GphA2BQAAAAUAAAAFAAAAYS50eHRoZWxsb1BLAQIeAwoAAAAAAG+2T12GphA2BQAAAAUAAAAFAAAAAAAAAAAAAACkgQAAAABhLnR4dFBLBQYAAAAAAQABADMAAAAoAAAAAAA="
    // for i in $(seq 20); do printf 'globalThis.search = 1;\n'; done > plugin.js && zip -9 -X d.zip plugin.js && base64 -i d.zip
    let deflated = "UEsDBBQAAgAIAG+2T12gXm2DHgAAAMwBAAAJAAAAcGx1Z2luLmpzS8/JT0rMCcnILNYrTk0sSs5QsFUwtOZKHxUeesIAUEsBAh4DFAACAAgAb7ZPXaBebYMeAAAAzAEAAAkAAAAAAAAAAQAAAKSBAAAAAHBsdWdpbi5qc1BLBQYAAAAAAQABADcAAABFAAAAAAA="

    func testStoredFile() {
        let text = ZipReader.file(named: "a.txt", in: Data(base64Encoded: stored)!).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(text, "hello")
    }

    func testDeflatedFile() {
        let text = ZipReader.file(named: "plugin.js", in: Data(base64Encoded: deflated)!).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(text, String(repeating: "globalThis.search = 1;\n", count: 20))
    }

    func testMissingFileAndGarbage() {
        XCTAssertNil(ZipReader.file(named: "nope", in: Data(base64Encoded: stored)!))
        XCTAssertNil(ZipReader.file(named: "a.txt", in: Data("not a zip".utf8)))
    }

    func testAnEntryClaimingAHugeSizeIsRefused() {
        // The deflated fixture with its central-directory size set to 0x7FFFFFFF: a hostile .sky
        // would otherwise make the reader allocate gigabytes.
        var bytes = [UInt8](Data(base64Encoded: deflated)!)
        let eocd = bytes.count - 22
        let cd = Int(bytes[eocd + 16]) | Int(bytes[eocd + 17]) << 8
        bytes.replaceSubrange((cd + 24)..<(cd + 28), with: [0xff, 0xff, 0xff, 0x7f])
        XCTAssertNil(ZipReader.file(named: "plugin.js", in: Data(bytes)))
        // The limit is what keeps that from being allocated: a real file over it is refused too.
        XCTAssertNil(ZipReader.file(named: "plugin.js", in: Data(base64Encoded: deflated)!, maxSize: 100))
        XCTAssertNotNil(ZipReader.file(named: "plugin.js", in: Data(base64Encoded: deflated)!, maxSize: 1000))
    }
}
