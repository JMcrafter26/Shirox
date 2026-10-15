import Foundation

/// One person using the app on this device: their own library, progress, settings and
/// sign-ins, and modules either their own or shared with other profiles.
///
/// Only the active profile's data is where the app reads it; the rest is kept aside by
/// `ProfileSwap`, which swaps it in at launch.
struct AppProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    /// The default picture's colour, `#RRGGBB`, picked so no two profiles share one.
    var colorHex: String
    /// A picture the user chose for it, kept under `Profiles/photos/`.
    var hasPhoto: Bool = false
    /// The picture of its first signed-in account, AniList, then MyAnimeList, then Simkl,
    /// remembered so it shows while the profile isn't the active one.
    var accountAvatarURL: String?
    /// Profiles with the same group share one set of modules.
    var moduleGroup: UUID
    var createdAt: Date = Date()

    var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }
}

/// The profiles on this device, which one is active, and which to switch to at the next launch.
struct ProfileRegistry: Codable, Equatable {
    var profiles: [AppProfile]
    var activeID: UUID
    /// Set when the user switches; the swap happens at the next launch, before anything loads.
    var pendingID: UUID?

    var active: AppProfile? { profiles.first { $0.id == activeID } }
}

/// The default pictures' colours.
enum ProfilePalette {
    static let colors = [
        "#E5484D", "#F76B15", "#FFC53D", "#46A758", "#12A594", "#00A2C7",
        "#3E63DD", "#6E56CF", "#AB4ABA", "#D6409F", "#8D6E63", "#5B6B7A",
    ]

    /// A colour no existing profile has: a random unused one from the palette, and once all
    /// twelve are taken, the hue farthest from every one in use.
    static func pick(avoiding used: [String], random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        let taken = Set(used.map { $0.uppercased() })
        let free = colors.filter { !taken.contains($0) }
        if !free.isEmpty { return free[random(free.count)] }
        let usedHues = used.compactMap(hue)
        let best = stride(from: 0.0, to: 360.0, by: 5.0).max { a, b in
            distance(a, to: usedHues) < distance(b, to: usedHues)
        } ?? 0
        return hex(hue: best, saturation: 0.62, brightness: 0.82)
    }

    private static func distance(_ hue: Double, to hues: [Double]) -> Double {
        hues.map { min(abs($0 - hue), 360 - abs($0 - hue)) }.min() ?? 360
    }

    /// The hue of `#RRGGBB`, in degrees.
    static func hue(_ hex: String) -> Double? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
        guard delta > 0 else { return 0 }
        var h: Double
        if maxV == r { h = (g - b) / delta } else if maxV == g { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func hex(hue: Double, saturation s: Double, brightness v: Double) -> String {
        let c = v * s
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return String(format: "#%02X%02X%02X", Int(((r + m) * 255).rounded()),
                      Int(((g + m) * 255).rounded()), Int(((b + m) * 255).rounded()))
    }
}
