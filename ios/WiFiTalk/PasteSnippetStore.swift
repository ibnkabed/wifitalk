import Foundation

/// One slot behind the clipboard button in the header: a title shown in the
/// list and the text typed into the computer when it is tapped.
struct PasteSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var text = ""

    /// Only a slot with both a title and a text appears in the list (owner,
    /// 2026-10-31): an empty one is a slot waiting in the settings.
    var isFilled: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.isEmpty
    }
}

/// The snippets live on the phone alone, like the key button's PIN, so the
/// button works without a model and without anything on the computer
/// (owner, 2026-10-31). They are not secrets, so UserDefaults is enough.
enum PasteSnippetStore {
    static let limit = 10
    private static let key = "wifiTalkPasteSnippets"

    static func read(_ defaults: UserDefaults = .standard) -> [PasteSnippet] {
        guard let data = defaults.data(forKey: key),
              let snippets = try? JSONDecoder().decode([PasteSnippet].self, from: data)
        else { return [] }
        return Array(snippets.prefix(limit))
    }

    static func save(_ snippets: [PasteSnippet], _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Array(snippets.prefix(limit))) else { return }
        defaults.set(data, forKey: key)
    }
}
