import Foundation
import Combine

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var created = Date()
    var modified = Date()

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var meaningfulLines: [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The first non-empty line doubles as the note's title.
    var title: String {
        meaningfulLines.first.map { String($0.prefix(60)) } ?? "New note"
    }

    var preview: String {
        String(meaningfulLines.dropFirst().joined(separator: " ").prefix(90))
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// Holds every note in memory and mirrors them to a JSON file. Edits are saved
/// automatically a moment after typing stops, and immediately on close/quit.
@MainActor
final class NotesStore: NSObject, ObservableObject {
    private struct Persisted: Codable {
        var notes: [Note]
        var selectedID: UUID?
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var hasUnsavedChanges = false
    /// UI state: whether the notes list (rather than the editor) is showing.
    @Published var showingList = false
    /// Bumped whenever the editor should grab keyboard focus.
    @Published private(set) var focusTick = 0

    let fileURL: URL
    private var saveTimer: Timer?

    /// - Parameter directory: where `notes.json` lives. Defaults to
    ///   `~/Library/Application Support/PurrNotes`.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        fileURL = dir.appendingPathComponent("notes.json")
        super.init()
        load()
    }

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PURRNOTES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PurrNotes", isDirectory: true)
    }

    // MARK: Reading

    var currentNote: Note? { notes.first { $0.id == selectedID } }
    var sortedNotes: [Note] { notes.sorted { $0.modified > $1.modified } }

    // MARK: Editing

    func updateCurrentText(_ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == selectedID }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].modified = Date()
        scheduleSave()
    }

    func newNote() {
        showingList = false
        focusTick += 1
        if let current = currentNote, current.isBlank { return }
        let note = Note()
        notes.append(note)
        selectedID = note.id
        scheduleSave()
    }

    func select(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        pruneBlankNotes(keeping: id)
        selectedID = id
        showingList = false
        focusTick += 1
        scheduleSave()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        ensureSelection()
        scheduleSave()
    }

    /// Guarantees there is a selected note to type into, creating one if needed.
    func ensureSelection() {
        guard currentNote == nil else { return }
        if let recent = sortedNotes.first {
            selectedID = recent.id
        } else {
            let note = Note()
            notes.append(note)
            selectedID = note.id
        }
    }

    func requestFocus() { focusTick += 1 }

    /// Called when the notes window closes: drop empty notes and write to disk.
    func tidyAndSave() {
        pruneBlankNotes(keeping: nil)
        if currentNote == nil { selectedID = sortedNotes.first?.id }
        showingList = false
        flush()
    }

    private func pruneBlankNotes(keeping id: UUID?) {
        notes.removeAll { $0.isBlank && $0.id != id }
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let welcome = Note(text: """
            Hi, I'm your note cat 🐾

            Click me any time to jot something down. Everything you write is saved automatically.

            • Drag me around and I'll land back on my feet
            • Right-click me for more options
            """)
            notes = [welcome]
            selectedID = welcome.id
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode(Persisted.self, from: Data(contentsOf: fileURL))
            notes = saved.notes
            selectedID = saved.selectedID
            if currentNote == nil { selectedID = sortedNotes.first?.id }
        } catch {
            // Never overwrite a file we couldn't read: set it aside so nothing is lost.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("notes.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("PurrNotes: could not read notes (%@). Moved the file to %@", "\(error)", backup.path)
        }
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(saveTimerFired),
                                         userInfo: nil, repeats: false)
    }

    @objc private func saveTimerFired() { flush() }

    /// Writes immediately. Safe to call at any time.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Persisted(notes: notes, selectedID: selectedID))
            try data.write(to: fileURL, options: .atomic)
            hasUnsavedChanges = false
        } catch {
            NSLog("PurrNotes: saving notes failed: %@", "\(error)")
        }
    }
}
