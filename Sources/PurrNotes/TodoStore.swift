import Foundation
import Combine

struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var isDone = false
    var created = Date()
    var completedAt: Date?

    init(title: String) {
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case id, title, isDone, created, completedAt }

    // Tolerant decoding: a field missing from an older or hand-edited file falls
    // back to a default instead of making the whole list unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// Holds the to-do list and mirrors it to `todos.json`, next to `notes.json`.
/// Like the notes, changes are saved a moment after they happen and again on
/// close and quit. The notes file is never read or written from here.
@MainActor
final class TodoStore: NSObject, ObservableObject {
    private struct Persisted: Codable {
        var items: [TodoItem]
    }

    @Published private(set) var items: [TodoItem] = []
    @Published private(set) var hasUnsavedChanges = false

    let fileURL: URL
    private var saveTimer: Timer?

    init(directory: URL? = nil) {
        fileURL = (directory ?? NotesStore.defaultDirectory).appendingPathComponent("todos.json")
        super.init()
        load()
    }

    // MARK: Reading

    /// Tasks still to do, oldest first, so the list reads top to bottom in the order they were added.
    var pending: [TodoItem] { items.filter { !$0.isDone } }

    /// Finished tasks, most recently finished first.
    var completed: [TodoItem] {
        items.filter(\.isDone).sorted { ($0.completedAt ?? $0.created) > ($1.completedAt ?? $1.created) }
    }

    // MARK: Editing

    /// Adds a task. Blank or whitespace-only text is ignored; returns whether anything was added.
    @discardableResult
    func add(_ text: String) -> Bool {
        let title = Self.clean(text)
        guard !title.isEmpty else { return false }
        items.append(TodoItem(title: title))
        scheduleSave()
        return true
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isDone.toggle()
        items[i].completedAt = items[i].isDone ? Date() : nil
        scheduleSave()
    }

    /// Changes a task's text. Editing a task down to nothing leaves it unchanged.
    func rename(_ id: UUID, to text: String) {
        let title = Self.clean(text)
        guard !title.isEmpty, let i = items.firstIndex(where: { $0.id == id }), items[i].title != title else { return }
        items[i].title = title
        scheduleSave()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Tasks are single lines: collapse pasted newlines and trim the ends.
    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode(Persisted.self, from: Data(contentsOf: fileURL)).items
        } catch {
            // Never overwrite a file we couldn't read: set it aside so nothing is lost.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("todos.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("PurrNotes: could not read to-dos (%@). Moved the file to %@", "\(error)", backup.path)
        }
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(saveTimerFired),
                                         userInfo: nil, repeats: false)
    }

    @objc private func saveTimerFired() { flush() }

    /// Writes immediately if anything changed. Safe to call at any time.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard hasUnsavedChanges else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Persisted(items: items)).write(to: fileURL, options: .atomic)
            hasUnsavedChanges = false
        } catch {
            NSLog("PurrNotes: saving to-dos failed: %@", "\(error)")
        }
    }
}

/// Which page the window shows, plus focus requests for the to-do page.
/// The chosen tab is remembered between launches.
@MainActor
final class PanelState: ObservableObject {
    enum Tab: String { case notes, todo }

    private static let tabKey = "panelTab"

    @Published var tab: Tab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    /// Bumped whenever the "Add a task" field should grab keyboard focus.
    @Published private(set) var addTaskFocusTick = 0

    init() {
        tab = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(Tab.init(rawValue:)) ?? .notes
    }

    func focusAddTask() { addTaskFocusTick += 1 }
}
