import Foundation
#if os(iOS)
import UIKit
typealias HighlightColor = UIColor
typealias HighlightFont = UIFont
#elseif os(macOS)
import AppKit
typealias HighlightColor = NSColor
typealias HighlightFont = NSFont
#endif

#if os(iOS) || os(macOS)
/// Colours JavaScript as VS Code's default themes do: keywords, strings, comments, numbers and
/// the names of functions called or declared. Text only, no parsing: fast enough to run over a
/// whole module after each pause in typing.
enum JavaScriptHighlighter {
    enum Kind: CaseIterable { case keyword, string, comment, number, function }

    /// What each range is. Later kinds don't override comments and strings: a keyword inside a
    /// string stays string-coloured.
    static func ranges(in text: String) -> [(NSRange, Kind)] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var result: [(NSRange, Kind)] = []
        var covered = IndexSet()

        func add(_ regex: NSRegularExpression, _ kind: Kind, group: Int = 0, protected: Bool = false) {
            for match in regex.matches(in: text, range: whole) {
                let range = match.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let span = range.location..<(range.location + range.length)
                if covered.intersects(integersIn: span) { continue }
                result.append((range, kind))
                if protected { covered.insert(integersIn: span) }
            }
        }
        // Strings and comments first, in order of appearance, so `"//"` is a string and
        // `// "x"` a comment.
        for match in stringsAndComments.matches(in: text, range: whole) {
            let range = match.range
            let kind: Kind = ns.substring(with: NSRange(location: range.location, length: min(2, range.length)))
                .hasPrefix("/") ? .comment : .string
            result.append((range, kind))
            covered.insert(integersIn: range.location..<(range.location + range.length))
        }
        add(keywords, .keyword)
        add(numbers, .number)
        add(functions, .function, group: 1)
        return result
    }

    private static let stringsAndComments = try! NSRegularExpression(
        pattern: #"//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`"#)
    private static let keywords = try! NSRegularExpression(pattern: "\\b(?:" + [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
        "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in",
        "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this",
        "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "yield",
    ].joined(separator: "|") + ")\\b")
    private static let numbers = try! NSRegularExpression(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    private static let functions = try! NSRegularExpression(pattern: #"\b([A-Za-z_$][\w$]*)\s*(?=\()"#)

    // MARK: Colours

    static func color(_ kind: Kind) -> HighlightColor {
        switch kind {
        case .keyword: return dynamic(light: 0xAF00DB, dark: 0xC586C0)
        case .string: return dynamic(light: 0xA31515, dark: 0xCE9178)
        case .comment: return dynamic(light: 0x008000, dark: 0x6A9955)
        case .number: return dynamic(light: 0x098658, dark: 0xB5CEA8)
        case .function: return dynamic(light: 0x795E26, dark: 0xDCDCAA)
        }
    }

    private static func rgb(_ hex: Int) -> HighlightColor {
        HighlightColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(light: Int, dark: Int) -> HighlightColor {
        #if os(iOS)
        return UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
        #else
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
        #endif
    }

    /// Colours `storage` in place, leaving its text, and so the selection, alone.
    static func apply(to storage: NSTextStorage, font: HighlightFont) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        #if os(iOS)
        storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: whole)
        #else
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: whole)
        #endif
        for (range, kind) in ranges(in: storage.string) {
            storage.addAttribute(.foregroundColor, value: color(kind), range: range)
        }
        storage.endEditing()
    }
}
#endif
