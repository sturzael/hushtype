import Foundation

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var text: String
    var app: String?
}

final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var items: [HistoryItem] = []
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Speakhold")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
    }

    func add(_ text: String, app: String?) {
        items.insert(HistoryItem(date: Date(), text: text, app: app), at: 0)
        if items.count > 200 { items = Array(items.prefix(200)) }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url) }
    }

    func clear() {
        items = []
        try? FileManager.default.removeItem(at: url)
    }
}
