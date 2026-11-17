import SwiftUI

/// The To-Do page: an "Add a task" field on top, pending tasks, then finished ones.
struct TodoListView: View {
    @ObservedObject var todos: TodoStore
    @ObservedObject var panel: PanelState

    @State private var newTask = ""
    @State private var editingID: UUID?
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addField
            Divider().opacity(0.5)
            if todos.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        // Opening the page focuses "Add a task", but never at the expense of an edit
        // the user has already started. An explicit "New Task" request does end it.
        .onAppear { focusAddField(endingEdit: false) }
        .onChange(of: panel.addTaskFocusTick) { _ in focusAddField(endingEdit: true) }
    }

    private func focusAddField(endingEdit: Bool) {
        if endingEdit { editingID = nil }
        guard editingID == nil else { return }
        Task { @MainActor in
            if editingID == nil { addFieldFocused = true }
        }
    }

    // MARK: Add

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
            TextField("Add a task…", text: $newTask)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(Theme.ink)
                .focused($addFieldFocused)
                .onSubmit(addTask)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func addTask() {
        withAnimation(.easeOut(duration: 0.18)) {
            if todos.add(newTask) { newTask = "" }
        }
        // Stay in the field so several tasks can be typed in a row.
        Task { @MainActor in addFieldFocused = true }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            // A plain VStack: to-do lists are short, and the lazy stack kept showing a
            // moved row's old look after it was checked off.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(todos.pending) { row(for: $0) }

                if !todos.completed.isEmpty {
                    Text("Completed · \(todos.completed.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.45))
                        .padding(.horizontal, 10)
                        .padding(.top, todos.pending.isEmpty ? 2 : 12)
                        .padding(.bottom, 2)
                    ForEach(todos.completed) { row(for: $0) }
                }
            }
            .padding(8)
        }
    }

    private func row(for item: TodoItem) -> some View {
        // Checking a task off moves it to the other section. Including the done
        // state in the row's identity guarantees it is redrawn with its new look.
        TodoRow(item: item,
                isEditing: editingID == item.id,
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.22)) { todos.toggle(item.id) }
                },
                onBeginEdit: { editingID = item.id },
                onCommit: { text in
                    todos.rename(item.id, to: text)
                    if editingID == item.id { editingID = nil }
                },
                onCancel: {
                    if editingID == item.id { editingID = nil }
                },
                onDelete: {
                    if editingID == item.id { editingID = nil }
                    withAnimation(.easeOut(duration: 0.18)) { todos.delete(item.id) }
                })
            .id("\(item.id.uuidString)-\(item.isDone)")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent.opacity(0.8))
            Text("Nothing to do yet")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.7))
            Text("Type a task above and press Return.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One task: a checkbox, its text, and edit / delete buttons that appear on hover.
/// Double-click the text (or use the pencil) to edit it in place.
private struct TodoRow: View {
    let item: TodoItem
    let isEditing: Bool
    let onToggle: () -> Void
    let onBeginEdit: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var draft = ""
    @State private var cancelled = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: item.isDone ? .regular : .light))
                    .foregroundStyle(item.isDone ? Theme.accent.opacity(0.75) : Theme.ink.opacity(0.45))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(item.isDone ? "Completed" : "Not completed")

            if isEditing {
                editField
            } else {
                Text(item.title)
                    .font(.system(size: 13.5, design: .rounded))
                    .strikethrough(item.isDone, color: Theme.ink.opacity(0.45))
                    .foregroundStyle(Theme.ink.opacity(item.isDone ? 0.45 : 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onBeginEdit)
            }

            if hovering && !isEditing {
                HStack(spacing: 0) {
                    RowButton(symbol: "pencil", help: "Edit", action: onBeginEdit)
                    RowButton(symbol: "trash", help: "Delete", action: onDelete)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isEditing ? Theme.accent.opacity(0.12) : Theme.ink.opacity(hovering ? 0.06 : 0))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button(item.isDone ? "Mark as Not Done" : "Mark as Done", action: onToggle)
            Button("Edit", action: onBeginEdit)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onChange(of: isEditing) { editing in
            guard editing else { return }
            draft = item.title
            cancelled = false
            Task { @MainActor in fieldFocused = true }
        }
    }

    private var editField: some View {
        TextField("Task", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, design: .rounded))
            .foregroundColor(Theme.ink)
            .focused($fieldFocused)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                draft = item.title
                cancelled = false
                Task { @MainActor in fieldFocused = true }
            }
            // Return saves, Esc cancels, clicking elsewhere saves.
            .onSubmit { onCommit(draft) }
            .onExitCommand {
                cancelled = true
                onCancel()
            }
            .onChange(of: fieldFocused) { focused in
                if !focused && isEditing && !cancelled { onCommit(draft) }
            }
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(hovering ? 0.9 : 0.5))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.ink.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
