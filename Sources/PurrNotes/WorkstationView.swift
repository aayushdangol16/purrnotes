import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Workstation page: one big Start / End button, then the apps it opens, in order.
struct WorkstationView: View {
    @ObservedObject var workstation: Workstation

    @State private var expandedID: UUID?
    @State private var confirmingEnd = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            if workstation.needsFullScreenPermission { permissionBanner }
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    listHeader
                    if workstation.apps.isEmpty {
                        Text("No apps yet. Click “Add App…” to choose the apps your workstation should open.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.ink.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    }
                    ForEach(Array(workstation.apps.enumerated()), id: \.element.id) { index, app in
                        WorkstationAppRow(
                            workstation: workstation,
                            app: app,
                            position: index + 1,
                            isFirst: index == 0,
                            isLast: index == workstation.apps.count - 1,
                            expanded: expandedID == app.id,
                            onToggleExpanded: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedID = expandedID == app.id ? nil : app.id
                                }
                            })
                    }
                    pauseSetting
                }
                .padding(8)
            }
        }
        .confirmationDialog(endTitle, isPresented: $confirmingEnd) {
            Button("Quit Apps and End", role: .destructive) { Task { await workstation.end() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps that were already open before you started stay open. Apps with unsaved work will ask before quitting.")
        }
    }

    // MARK: Start / End

    private var endTitle: String {
        let names = workstation.ownedRunning.map(\.name)
        return "Quit \(ListFormatter.localizedString(byJoining: names))?"
    }

    private var controls: some View {
        VStack(spacing: 7) {
            switch workstation.phase {
            case .idle:
                BigButton(title: "Start Workstation", symbol: "play.fill", tint: Theme.accent,
                          disabled: workstation.enabledApps.isEmpty) {
                    Task { await workstation.start() }
                }
                Text(startHint)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.5))
            case .starting, .ending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(workstation.phase == .starting ? "Opening apps…" : "Closing apps…")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.8))
                }
                .frame(height: 34)
            case .active:
                BigButton(title: "End Workstation", symbol: "stop.fill", tint: Color(red: 0.82, green: 0.36, blue: 0.32),
                          disabled: false) {
                    if workstation.ownedRunning.isEmpty {
                        Task { await workstation.end() }
                    } else {
                        confirmingEnd = true
                    }
                }
                Text(runningHint)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.5))
            }
            if let message = workstation.message {
                Text(message)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full screen needs your permission")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                Text("Switch PurrNotes on in Privacy & Security › Accessibility. Until then apps open normally.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Allow…") { FullScreen.askForPermission() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        // While the banner is up, notice as soon as the permission is granted.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            workstation.refreshPermission()
        }
    }

    private var startHint: String {
        let count = workstation.enabledApps.count
        if count == 0 { return "Switch on at least one app below." }
        return "Opens \(count) app\(count == 1 ? "" : "s"), top to bottom."
    }

    private var runningHint: String {
        _ = workstation.refreshTick
        let count = workstation.ownedRunning.count
        if count == 0 { return "Nothing opened by the workstation is still running." }
        return "Will quit the \(count) app\(count == 1 ? "" : "s") it opened. Others stay open."
    }

    // MARK: List

    private var listHeader: some View {
        HStack {
            Text("Apps · in launch order")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.ink.opacity(0.45))
            Spacer()
            Button {
                AppPicker.chooseApps { paths in paths.forEach(workstation.add(path:)) }
            } label: {
                Label("Add App…", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help("Choose apps to add to the workstation")
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var pauseSetting: some View {
        HStack(spacing: 6) {
            Text("Wait between apps")
            Spacer()
            Text(String(format: "%.1f s", workstation.pauseSeconds))
                .monospacedDigit()
            Stepper("", value: $workstation.pauseSeconds, in: 0...5, step: 0.5)
                .labelsHidden()
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(Theme.ink.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

/// One app: on/off checkbox, icon, name and status, reorder arrows and an options panel.
private struct WorkstationAppRow: View {
    @ObservedObject var workstation: Workstation
    let app: WorkstationApp
    let position: Int
    let isFirst: Bool
    let isLast: Bool
    let expanded: Bool
    let onToggleExpanded: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { app.enabled },
                                         set: { on in workstation.update(app.id) { $0.enabled = on } }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(app.enabled ? "Don't open this app" : "Open this app")

                // Resolve shortcuts (e.g. /Applications/Safari.app) so the icon has no alias arrow.
                Image(nsImage: NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .opacity(app.enabled ? 1 : 0.45)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(app.enabled ? 1 : 0.5))
                        .lineLimit(1)
                    if let status {
                        Text(status.text)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(status.color)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)

                if hovering || expanded {
                    HStack(spacing: 0) {
                        SmallIconButton(symbol: "chevron.up", help: "Open earlier", disabled: isFirst) {
                            withAnimation(.easeInOut(duration: 0.15)) { workstation.move(app.id, by: -1) }
                        }
                        SmallIconButton(symbol: "chevron.down", help: "Open later", disabled: isLast) {
                            withAnimation(.easeInOut(duration: 0.15)) { workstation.move(app.id, by: 1) }
                        }
                    }
                }
                SmallIconButton(symbol: expanded ? "chevron.up.circle.fill" : "ellipsis.circle",
                                help: expanded ? "Hide options" : "Options", disabled: false, action: onToggleExpanded)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggleExpanded)

            if expanded { options }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.ink.opacity(expanded ? 0.07 : (hovering ? 0.05 : 0)))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button(app.enabled ? "Don't Open" : "Open") { workstation.update(app.id) { $0.enabled.toggle() } }
            Button("Open Earlier") { workstation.move(app.id, by: -1) }.disabled(isFirst)
            Button("Open Later") { workstation.move(app.id, by: 1) }.disabled(isLast)
            Divider()
            Button("Remove from Workstation", role: .destructive) { workstation.remove(app.id) }
        }
    }

    // MARK: Status line

    private var status: (text: String, color: Color)? {
        _ = workstation.refreshTick
        if !workstation.isInstalled(app) {
            return ("Not found — open Options and click Change…", Color.red.opacity(0.8))
        }
        if let entry = workstation.entry(for: app) {
            switch entry.outcome {
            case .opened:
                guard Workstation.runningApp(for: entry) != nil else {
                    return ("Opened by Workstation · already closed", Theme.ink.opacity(0.45))
                }
                switch entry.fullScreen {
                case true?:
                    return ("Opened in full screen · will quit at the end", Color.green.opacity(0.85))
                case false?:
                    return ("Opened, not full screen (\(entry.fullScreenNote ?? "unknown reason")) · will quit at the end",
                            Color.orange.opacity(0.9))
                case nil:
                    return ("Opened by Workstation · will quit at the end", Color.green.opacity(0.85))
                }
            case .alreadyRunning:
                return ("Was already open · will stay open", Theme.ink.opacity(0.5))
            case .failed:
                return ("Couldn't open: \(entry.note ?? "unknown error")", Color.red.opacity(0.8))
            }
        }
        var bits: [String] = []
        if app.fullScreen && !app.startHidden { bits.append("full screen") }
        if app.startHidden { bits.append("starts hidden") }
        if !app.openTarget.isEmpty { bits.append("opens \(app.openTarget)") }
        return bits.isEmpty ? nil : (bits.joined(separator: " · ").capitalizedFirstLetter, Theme.ink.opacity(0.45))
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Open in full screen (its own Space)", isOn: Binding(
                get: { app.fullScreen && !app.startHidden },
                set: { on in workstation.update(app.id) { $0.fullScreen = on; if on { $0.startHidden = false } } }))
                .toggleStyle(.checkbox)
            Toggle("Start hidden (don't show its windows)", isOn: Binding(
                get: { app.startHidden },
                set: { on in workstation.update(app.id) { $0.startHidden = on; if on { $0.fullScreen = false } } }))
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 3) {
                Text("Also open (optional)")
                    .foregroundStyle(Theme.ink.opacity(0.6))
                HStack(spacing: 6) {
                    TextField("https://… or a file / folder", text: Binding(
                        get: { app.openTarget },
                        set: { text in workstation.update(app.id) { $0.openTarget = text } }))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        AppPicker.chooseFileOrFolder { path in
                            workstation.update(app.id) { $0.openTarget = (path as NSString).abbreviatingWithTildeInPath }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("App location")
                    .foregroundStyle(Theme.ink.opacity(0.6))
                HStack(spacing: 6) {
                    Text((app.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Theme.ink.opacity(0.75))
                        .help(app.path)
                    Spacer(minLength: 4)
                    Button("Change…") {
                        AppPicker.chooseApp(startingAt: app.path) { path in workstation.changePath(app.id, to: path) }
                    }
                }
            }

            HStack {
                Text("Opens #\(position) in order")
                    .foregroundStyle(Theme.ink.opacity(0.45))
                Spacer()
                Button(role: .destructive) {
                    workstation.remove(app.id)
                } label: {
                    Text("Remove")
                }
            }
        }
        .font(.system(size: 11.5, design: .rounded))
        .padding(.horizontal, 36)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }
}

private struct BigButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(disabled ? 0.35 : (hovering ? 1 : 0.9)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

private struct SmallIconButton: View {
    let symbol: String
    let help: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(disabled ? 0.2 : (hovering ? 0.9 : 0.5)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// File pickers, shown as a sheet on the notes window so they never end up
/// hidden behind it.
@MainActor
enum AppPicker {
    static func chooseApps(_ done: @escaping ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Choose the apps your workstation should open."
        present(panel) { done($0.map(\.path)) }
    }

    static func chooseApp(startingAt path: String, _ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        panel.prompt = "Use This App"
        present(panel) { if let first = $0.first { done(first.path) } }
    }

    static func chooseFileOrFolder(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose a file or folder for the app to open."
        present(panel) { if let first = $0.first { done(first.path) } }
    }

    private static func present(_ panel: NSOpenPanel, _ done: @escaping ([URL]) -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { done(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            done(panel.urls)
        }
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
