import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("smartCleanupEnabled") var smartCleanupEnabled = true
    @AppStorage("promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("bedrockBearerToken") var bedrockBearerToken = ""
    @AppStorage("bedrockRegion") var bedrockRegion = "us-east-1"
    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled = true
    @AppStorage("sessionNamingTheme") var sessionNamingTheme: SessionNamingTheme = .gameOfThrones
}

// MARK: - Session Naming Themes

enum SessionNamingTheme: String, CaseIterable, Identifiable {
    case gameOfThrones = "gameOfThrones"
    case viking = "viking"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gameOfThrones: return "Game of Thrones"
        case .viking: return "Viking"
        }
    }

    var names: [String] {
        switch self {
        case .gameOfThrones: return Self.gotNames
        case .viking: return Self.vikingNames
        }
    }

    static let gotNames = [
        "Arya", "Tyrion", "Daenerys", "Jon Snow", "Cersei",
        "Sansa", "Bran", "Jaime", "Brienne", "Theon",
        "Samwell", "Jorah", "Davos", "Missandei", "Varys",
        "Tormund", "Podrick", "Gendry", "Bronn", "Sandor",
        "Melisandre", "Ygritte", "Oberyn", "Margaery", "Olenna",
        "Ramsay", "Stannis", "Robb", "Catelyn", "Ned",
        "Hodor", "Gilly", "Drogo", "Viserys", "Littlefinger",
        "Tywin", "Joffrey", "Tommen", "Myrcella", "Rickon",
        "Osha", "Shae", "Yara", "Euron", "Ellaria",
        "Grey Worm", "Barristan", "Jojen", "Meera", "Benjen",
        "Lyanna", "Rhaegar", "Aemon", "Qyburn", "Septa",
        "Ros", "Talisa", "Edmure", "Blackfish", "Walder Frey",
        "Loras", "Renly", "Robert", "Lancel", "Hot Pie",
        "Nymeria", "Ghost", "Drogon", "Rhaegal", "Viserion"
    ]

    static let vikingNames = [
        "Ragnar", "Lagertha", "Bjorn", "Rollo", "Floki",
        "Ivar", "Ubbe", "Sigurd", "Hvitserk", "Aslaug",
        "Athelstan", "Helga", "Torvi", "Harald", "Halfdan",
        "Freydis", "Leif", "Erik", "Gunnar", "Sigrid",
        "Thorstein", "Ingrid", "Arne", "Astrid", "Brynhild",
        "Gudrun", "Hakon", "Knut", "Olaf", "Sven",
        "Thyra", "Ulf", "Viggo", "Ylva", "Idunn",
        "Fenrir", "Odin", "Thor", "Freya", "Tyr",
        "Heimdall", "Baldur", "Loki", "Skadi", "Njord",
        "Valkyrie", "Berserker", "Jarl", "Thane", "Skald",
        "Rune", "Saga", "Edda", "Volva", "Gorm",
        "Canute", "Sweyn", "Magnus", "Sigmund", "Bragi",
        "Eira", "Solveig", "Revna", "Hilda", "Torunn",
        "Vidar", "Hermod", "Ran", "Aegir", "Mimir"
    ]
}
