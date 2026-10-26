import Foundation

/// Why a link given to Add Module isn't a module — named for what the link is,
/// with the link to paste instead.
enum ModuleLinkError: LocalizedError, Equatable {
    case unreachable(Int)
    case image
    case webPage
    case script
    case seanimeList
    case notAModule
    case adult
    case cloudStream

    var errorDescription: String? {
        switch self {
        case .unreachable(let status):
            return String(localized: "modules.that_link_answered_with_error \(status)")
        case .image:
            return String(localized: "modules.that_link_is_an_image")
        case .webPage:
            return String(localized: "modules.that_link_is_a_web")
        case .script:
            return String(localized: "modules.that_link_is_a_script")
        case .seanimeList:
            return String(localized: "modules.that_link_is_a_list")
        case .notAModule:
            return String(localized: "modules.that_link_isnt_a_module")
        case .adult:
            return String(localized: "modules.shirox_doesnt_add_adult_modules")
        case .cloudStream:
            return String(localized: "modules.that_link_is_a_cloudstream")
        }
    }

    /// What a link that didn't decode as a module holds instead.
    static func diagnose(_ data: Data, response: URLResponse?, url: URL) -> ModuleLinkError {
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 { return .unreachable(status) }
        if isImage(data) || response?.mimeType?.hasPrefix("image/") == true { return .image }

        let text = String(decoding: data.prefix(4_096), as: UTF8.self)
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if start.hasPrefix("<svg") || (start.hasPrefix("<?xml") && start.contains("<svg")) { return .image }
        if start.hasPrefix("<") { return .webPage }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let list = json as? [[String: Any]], list.contains(where: { $0["manifestURI"] != nil || $0["payloadURI"] != nil }) {
                return .seanimeList
            }
            return .notAModule
        }
        if ["js", "ts", "mjs", "cjs"].contains(url.pathExtension.lowercased())
            || text.contains("class Provider") || text.contains("function ") {
            return .script
        }
        return .notAModule
    }

    /// PNG, JPEG, GIF or WebP, by their opening bytes.
    private static func isImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<offset + signature.count]) == signature
        }
        return starts([0x89, 0x50, 0x4E, 0x47])
            || starts([0xFF, 0xD8, 0xFF])
            || starts(Array("GIF8".utf8))
            || (starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8))
    }
}
