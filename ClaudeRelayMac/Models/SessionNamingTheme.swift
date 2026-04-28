import Foundation

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
        "Tywin", "Joffrey", "Tommen", "Myrcella", "Rickon"
    ]

    static let vikingNames = [
        "Ragnar", "Lagertha", "Bjorn", "Rollo", "Floki",
        "Ivar", "Ubbe", "Sigurd", "Hvitserk", "Aslaug",
        "Athelstan", "Helga", "Torvi", "Harald", "Halfdan",
        "Freydis", "Leif", "Erik", "Gunnar", "Sigrid",
        "Thorstein", "Ingrid", "Arne", "Astrid", "Brynhild",
        "Odin", "Thor", "Freya", "Tyr", "Loki"
    ]

    static let starWarsNames = [
        "Luke", "Leia", "Han Solo", "Chewie", "Vader",
        "Obi-Wan", "Yoda", "Palpatine", "Anakin", "Padme",
        "Ahsoka", "Rex", "Mace Windu", "Qui-Gon", "Maul",
        "Dooku", "Grievous", "Tarkin", "Lando", "Boba Fett",
        "Rey", "Kylo Ren", "Finn", "Poe", "Hux",
        "Din Djarin", "Grogu", "Bo-Katan", "Cara Dune", "Greef"
    ]

    static let duneNames = [
        "Paul", "Chani", "Leto", "Jessica", "Stilgar",
        "Duncan", "Gurney", "Thufir", "Alia", "Irulan",
        "Feyd", "Baron", "Rabban", "Piter", "Shaddam",
        "Liet", "Harah", "Jamis", "Mohiam", "Mapes",
        "Idaho", "Ghanima", "Farad'n", "Usul", "Muad'Dib"
    ]

    static let lotrNames = [
        "Frodo", "Sam", "Gandalf", "Aragorn", "Legolas",
        "Gimli", "Boromir", "Merry", "Pippin", "Gollum",
        "Saruman", "Sauron", "Elrond", "Galadriel", "Arwen",
        "Eowyn", "Theoden", "Eomer", "Faramir", "Denethor",
        "Treebeard", "Radagast", "Bilbo", "Thorin", "Balin",
        "Dwalin", "Fili", "Kili", "Smaug", "Shelob"
    ]
}
