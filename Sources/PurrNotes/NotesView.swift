import SwiftUI
import AppKit

enum Theme {
    static let paper = dynamic(light: 0xFFF9EC, dark: 0x2A2521)
    static let header = dynamic(light: 0xFBEED6, dark: 0x352E29)
    static let ink = dynamic(light: 0x3D2E22, dark: 0xF3E8DA)
    static let accent = Color(red: 0.93, green: 0.55, blue: 0.24)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

/// The window's content: a Notes / To-Do / Work switch in the header, then the chosen page.
struct NotesRootView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var todos: TodoStore
    @ObservedObject var panel: PanelState
    @ObservedObject var workstation: Workstation
    var onClose: () -> Void

    @State private var confirmingDelete = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if panel.tab == .todo {
                    TodoListView(todos: todos, panel: panel)
                } else if panel.tab == .work {
                    WorkstationView(workstation: workstation)
                } else if store.showingList {
                    list
                } else {
                    editor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Theme.paper)
        .frame(minWidth: NotesWindowController.minSize.width, minHeight: NotesWindowController.minSize.height)
        .ignoresSafeArea()
        .tint(Theme.accent)
        .onChange(of: store.focusTick) { _ in
            if panel.tab == .notes { focusEditor() }
        }
        .onChange(of: panel.tab) { tab in
            if tab == .notes { focusEditor() }
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let id = store.selectedID { store.delete(id) }
                focusEditor()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(store.currentNote?.title ?? "")” will be removed for good.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            TabSwitch(tab: $panel.tab, pendingCount: todos.pending.count,
                      workActive: workstation.phase != .idle)
                .fixedSize()   // the page names must never be truncated
            Spacer(minLength: 4)
            if panel.tab == .notes {
                IconButton(symbol: store.showingList ? "chevron.left" : "list.bullet",
                           help: store.showingList ? "Back to note" : "All notes") {
                    store.showingList.toggle()
                }
                IconButton(symbol: "square.and.pencil", help: "New note (⌘N)") {
                    store.newNote()
                }
                if !store.showingList {
                    IconButton(symbol: "trash", help: "Delete note") {
                        guard let note = store.currentNote else { return }
                        if note.isBlank {
                            store.delete(note.id)
                            focusEditor()
                        } else {
                            confirmingDelete = true
                        }
                    }
                }
            }
            IconButton(symbol: "xmark", help: "Close (⌘W)", action: onClose)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Theme.header)
    }

    // MARK: Editor

    private var text: Binding<String> {
        Binding(get: { store.currentNote?.text ?? "" },
                set: { store.updateCurrentText($0) })
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 14, design: .rounded))
                .lineSpacing(3)
                .foregroundColor(Theme.ink)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .id(store.selectedID)
            if (store.currentNote?.text ?? "").isEmpty {
                Text("Write something…")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.35))
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .onAppear { focusEditor() }
    }

    private func focusEditor() {
        Task { @MainActor in editorFocused = true }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(store.sortedNotes) { note in
                    NoteRow(note: note, selected: note.id == store.selectedID)
                        .onTapGesture { store.select(note.id) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.delete(note.id) }
                        }
                }
            }
            .padding(8)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 5) {
            let saving = store.hasUnsavedChanges || todos.hasUnsavedChanges || workstation.hasUnsavedChanges
            Circle()
                .fill(saving ? Theme.accent : Color.green.opacity(0.75))
                .frame(width: 6, height: 6)
            Text(saving ? "Saving…" : "Saved")
            Spacer()
            if panel.tab == .todo {
                Text("\(todos.pending.count) to do · \(todos.completed.count) done")
            } else if panel.tab == .work {
                Text("\(workstation.enabledApps.count) of \(workstation.apps.count) apps on")
            } else if store.showingList {
                Text(store.notes.count == 1 ? "1 note" : "\(store.notes.count) notes")
            } else {
                let words = store.currentNote?.wordCount ?? 0
                Text(words == 1 ? "1 word" : "\(words) words")
            }
        }
        .font(.system(size: 10.5, design: .rounded))
        .foregroundStyle(Theme.ink.opacity(0.5))
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.modified.formatted(.relative(presentation: .named)))
                    .layoutPriority(1)
                if !note.preview.isEmpty {
                    Text(note.preview).lineLimit(1)
                }
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Theme.ink.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.2) : Theme.ink.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The "Notes | To-Do | Work" pill switch. ⌘1, ⌘2 and ⌘3 switch pages from the keyboard.
private struct TabSwitch: View {
    @Binding var tab: PanelState.Tab
    let pendingCount: Int
    let workActive: Bool

    var body: some View {
        HStack(spacing: 2) {
            pill(.notes, title: "Notes", badge: nil, key: "1")
            pill(.todo, title: "To-Do", badge: pendingCount > 0 ? pendingCount : nil, key: "2")
            pill(.work, title: "Work", badge: nil, key: "3", dot: workActive, help: "Workstation")
        }
        .padding(2)
        .background(Capsule().fill(Theme.ink.opacity(0.08)))
    }

    private func pill(_ target: PanelState.Tab, title: String, badge: Int?, key: KeyEquivalent,
                      dot: Bool = false, help: String? = nil) -> some View {
        let selected = tab == target
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { tab = target }
        } label: {
            HStack(spacing: 4) {
                if dot {
                    // The workstation is running.
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                }
                Text(title)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(selected ? 0.3 : 0.2)))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.ink.opacity(selected ? 0.95 : 0.55))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(selected ? Theme.paper : Color.clear)
                    .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .help("\(help ?? title) (⌘\(String(key.character)))")
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.ink.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
