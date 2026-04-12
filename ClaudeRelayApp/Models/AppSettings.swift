import SwiftUI
import UIKit

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("smartCleanupEnabled") var smartCleanupEnabled = true
    @AppStorage("promptEnhancementEnabled") var promptEnhancementEnabled = false
    @AppStorage("bedrockBearerToken") var bedrockBearerToken = ""
    @AppStorage("bedrockRegion") var bedrockRegion = "us-east-1"
    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled = true
    @AppStorage("sessionNamingTheme") var sessionNamingTheme: SessionNamingTheme = .gameOfThrones
    @AppStorage("recordingShortcutEnabled") var recordingShortcutEnabled = true
    @AppStorage("recordingShortcutModifier") var recordingShortcutModifier: ShortcutModifier = .commandShift
    @AppStorage("recordingShortcutKey") var recordingShortcutKey = "r"
}

// MARK: - Keyboard Shortcut Modifier

enum ShortcutModifier: String, CaseIterable, Identifiable {
    case commandShift
    case commandOption
    case commandControl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commandShift: return "⌘⇧ Cmd + Shift"
        case .commandOption: return "⌘⌥ Cmd + Option"
        case .commandControl: return "⌘⌃ Cmd + Control"
        }
    }

    var symbol: String {
        switch self {
        case .commandShift: return "⌘⇧"
        case .commandOption: return "⌘⌥"
        case .commandControl: return "⌘⌃"
        }
    }

    var flags: UIKeyModifierFlags {
        switch self {
        case .commandShift: return [.command, .shift]
        case .commandOption: return [.command, .alternate]
        case .commandControl: return [.command, .control]
        }
    }
}

// MARK: - Session Naming Themes

enum SessionNamingTheme: String, CaseIterable, Identifiable {
    case gameOfThrones = "gameOfThrones"
    case viking = "viking"
    case starWars = "starWars"
    case dune = "dune"
    case lordOfTheRings = "lordOfTheRings"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gameOfThrones: return "Game of Thrones"
        case .viking: return "Viking"
        case .starWars: return "Star Wars"
        case .dune: return "Dune"
        case .lordOfTheRings: return "Lord of the Rings"
        }
    }

    var names: [String] {
        switch self {
        case .gameOfThrones: return Self.gotNames
        case .viking: return Self.vikingNames
        case .starWars: return Self.starWarsNames
        case .dune: return Self.duneNames
        case .lordOfTheRings: return Self.lotrNames
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

    static let starWarsNames = [
        "Luke", "Leia", "Han Solo", "Chewie", "Vader",
        "Obi-Wan", "Yoda", "Palpatine", "Anakin", "Padme",
        "Ahsoka", "Rex", "Mace Windu", "Qui-Gon", "Maul",
        "Dooku", "Grievous", "Tarkin", "Lando", "Boba Fett",
        "Jango", "Jabba", "Wedge", "Ackbar", "Mon Mothma",
        "Bail", "Poe", "Finn", "Rey", "Kylo Ren",
        "Hux", "Phasma", "Snoke", "Rose", "Maz Kanata",
        "Din Djarin", "Grogu", "Bo-Katan", "Cara Dune", "Greef",
        "Fennec", "Cad Bane", "Ventress", "Savage", "Satine",
        "Hera", "Kanan", "Ezra", "Sabine", "Zeb",
        "Chopper", "Thrawn", "Kallus", "Cassian", "Jyn Erso",
        "K-2SO", "Chirrut", "Baze", "Saw", "Galen",
        "Nien Nunb", "Biggs", "Porkins", "Lobot", "Bossk",
        "IG-88", "Dengar", "Zuckuss", "4-LOM", "Enfys Nest"
    ]

    static let duneNames = [
        "Paul", "Chani", "Leto", "Jessica", "Stilgar",
        "Duncan", "Gurney", "Thufir", "Alia", "Irulan",
        "Feyd", "Baron", "Rabban", "Piter", "Shaddam",
        "Liet", "Harah", "Jamis", "Mohiam", "Mapes",
        "Idaho", "Ghanima", "Farad'n", "Wensicia", "Javid",
        "Tuek", "Fenring", "Margot", "Scytale", "Bijaz",
        "Edric", "Korba", "Lichna", "Otheym", "Shishakli",
        "Naib", "Siona", "Hwi Noree", "Moneo", "Malky",
        "Taraza", "Odrade", "Lucilla", "Bellonda", "Murbella",
        "Teg", "Sheeana", "Waff", "Logno", "Dama",
        "Erasmus", "Omnius", "Serena", "Vorian", "Norma",
        "Aurelius", "Xavier", "Iblis", "Raquella", "Valya",
        "Tula", "Dorotea", "Gilbertus", "Manford", "Draigo",
        "Talamanes", "Reverend", "Sayyadina", "Usul", "Muad'Dib"
    ]

    static let lotrNames = [
        "Frodo", "Sam", "Gandalf", "Aragorn", "Legolas",
        "Gimli", "Boromir", "Merry", "Pippin", "Gollum",
        "Saruman", "Sauron", "Elrond", "Galadriel", "Arwen",
        "Eowyn", "Theoden", "Eomer", "Faramir", "Denethor",
        "Treebeard", "Tom Bombadil", "Goldberry", "Radagast", "Glorfindel",
        "Haldir", "Celeborn", "Thranduil", "Bilbo", "Thorin",
        "Balin", "Dwalin", "Fili", "Kili", "Bofur",
        "Bombur", "Bifur", "Oin", "Gloin", "Dori",
        "Nori", "Ori", "Beorn", "Bard", "Smaug",
        "Grima", "Shelob", "Gothmog", "Lurtz", "Ugluk",
        "Shagrat", "Gorbag", "Deagol", "Rosie", "Lobelia",
        "Hamfast", "Farmer Maggot", "Quickbeam", "Shadowfax", "Bill the Pony",
        "Witch-King", "Mouth of Sauron", "Gil-galad", "Isildur", "Elendil",
        "Cirdan", "Feanor", "Fingolfin", "Earendil", "Hurin"
    ]
}
