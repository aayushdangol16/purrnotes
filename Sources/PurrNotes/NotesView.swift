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

struct NotesRootView: View {
    @ObservedObject var store: NotesStore
    var onClose: () -> Void

    @State private var confirmingDelete = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if store.showingList { list } else { editor }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Theme.paper)
        .frame(minWidth: 260, minHeight: 240)
        .ignoresSafeArea()
        .tint(Theme.accent)
        .onChange(of: store.focusTick) { _ in focusEditor() }
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
        HStack(spacing: 4) {
            IconButton(symbol: store.showingList ? "chevron.left" : "list.bullet",
                       help: store.showingList ? "Back to note" : "All notes") {
                store.showingList.toggle()
            }
            Image(systemName: "pawprint.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .padding(.leading, 2)
            Text(store.showingList ? "Notes" : (store.currentNote?.title ?? "Notes"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
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
            Circle()
                .fill(store.hasUnsavedChanges ? Theme.accent : Color.green.opacity(0.75))
                .frame(width: 6, height: 6)
            Text(store.hasUnsavedChanges ? "Saving…" : "Saved")
            Spacer()
            if store.showingList {
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
