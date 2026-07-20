import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Apple Mail (in-app)

struct AppleMailView: View {
    @ObservedObject var mail: AppleMailService
    var onClose: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header(title: "Mail", systemImage: "envelope.fill", onClose: onClose) {
                Button {
                    Task { await mail.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh folders and messages")
                .disabled(mail.isLoadingFolders || mail.isLoadingList)

                Button {
                    mail.beginCompose()
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Compose and send a new email")
                .keyboardShortcut("n", modifiers: .command)
            }
            Divider().overlay(Theme.borderHairline)

            if let error = mail.errorMessage, mail.folders.isEmpty, mail.messages.isEmpty {
                permissionOrError(error)
            } else {
                HSplitView {
                    folderList
                        .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                    messageList
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                    messageDetail
                        .frame(minWidth: 300)
                }
            }
        }
        .background(Theme.centerBackground)
        .task { await mail.refreshAll() }
        .sheet(isPresented: $mail.showComposeSheet) {
            composeSheet
        }
    }

    // MARK: Folders

    private var folderList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Folders")
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if mail.isLoadingFolders { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(Theme.borderHairline)

            if mail.folders.isEmpty && !mail.isLoadingFolders {
                Text("No folders")
                    .font(Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(mail.folders) { folder in
                            Button {
                                Task { await mail.selectFolder(folder) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: folderIcon(folder.name))
                                        .font(Font.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(folder.shortName)
                                            .font(
                                                mail.selectedFolderID == folder.id
                                                    ? Font.subheadline.weight(.semibold)
                                                    : Font.subheadline
                                            )
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1)
                                        if !folder.account.isEmpty {
                                            Text(folder.account)
                                                .font(Font.caption2)
                                                .foregroundStyle(Theme.textTertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if folder.messageCount > 0 {
                                        Text(folder.messageCount > 999 ? "999+" : "\(folder.messageCount)")
                                            .font(Font.caption2.monospacedDigit())
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    mail.selectedFolderID == folder.id
                                        ? Theme.selectionFill
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .background(Theme.centerBackground)
    }

    private func folderIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "inbox": return "tray"
        case "drafts", "draft": return "doc"
        case "sent items", "sent": return "paperplane"
        case "deleted items", "trash": return "trash"
        case "junk email", "junk", "spam": return "xmark.bin"
        case "archive": return "archivebox"
        case "outbox": return "arrow.up.circle"
        default: return "folder"
        }
    }

    // MARK: Messages

    private var messageList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mail.selectedFolder?.shortName ?? "Messages")
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if mail.isLoadingList { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(Theme.borderHairline)

            if mail.messages.isEmpty && !mail.isLoadingList {
                Text(mail.selectedFolder == nil ? "Select a folder" : "No messages")
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(mail.messages) { msg in
                            Button {
                                Task { await mail.select(msg.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(msg.sender)
                                            .font(msg.isRead ? Font.subheadline : Font.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        if let d = msg.dateReceived {
                                            Text(d, style: .relative)
                                                .font(Font.caption2)
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                    }
                                    Text(msg.subject)
                                        .font(Font.caption.weight(msg.isRead ? .regular : .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(mail.selectedID == msg.id ? Theme.selectionFill : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .background(Theme.centerBackground)
    }

    // MARK: Detail + reply

    private var messageDetail: some View {
        VStack(spacing: 0) {
            if mail.isLoadingDetail {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = mail.detail {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail.subject)
                            .font(Font.title3.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(detail.sender)
                            .font(Font.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                        if let d = detail.dateReceived {
                            Text(d.formatted(date: .abbreviated, time: .shortened))
                                .font(Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if !detail.attachmentFiles.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(detail.attachmentFiles, id: \.path) { file in
                                        attachmentChip(file)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    Divider().overlay(Theme.borderHairline)

                    if let html = detail.htmlDocument {
                        MailHTMLWebView(html: html, baseURL: detail.htmlBaseURL)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            Text(detail.body)
                                .font(Font.body)
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                }

                Divider().overlay(Theme.borderHairline)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Picker("Mode", selection: $mail.responseMode) {
                            ForEach(AppleMailService.MailResponseMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        Spacer()

                        Button("Open in Mail") {
                            Task { await mail.revealInMailApp(id: detail.id) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    TextField(
                        mail.responseMode == .forward
                            ? "Add a note, then Send or Open Draft…"
                            : "Write your reply…",
                        text: $mail.responseDraft,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(3...8)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.elevatedSurface)
                    )

                    HStack(spacing: 8) {
                        if let err = mail.errorMessage {
                            Text(err)
                                .font(Font.caption)
                                .foregroundStyle(Theme.errorText)
                                .lineLimit(2)
                        } else if let status = mail.statusMessage {
                            Text(status)
                                .font(Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if mail.isSending {
                            ProgressView().controlSize(.small)
                        }
                        Button("Open Draft") {
                            Task { await mail.respondToSelected(send: false) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(mail.isSending)

                        Button("Send") {
                            Task { await mail.respondToSelected(send: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(mail.isSending)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    Text(mail.selectedFolder == nil ? "Select a folder" : "Select a message")
                        .font(Font.subheadline)
                        .foregroundStyle(Theme.textTertiary)
                    Button {
                        mail.beginCompose()
                    } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.centerBackground)
    }

    private func attachmentChip(_ file: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(Font.caption2)
            Text(file.lastPathComponent)
                .font(Font.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.chipBackground, in: Capsule())
        .foregroundStyle(Theme.textSecondary)
        .help("Drag into Files pane or Finder to save")
        // Drag attachment out of Mail into Prodigy Files / Finder.
        .onDrag {
            NSItemProvider(contentsOf: file) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
            Button("Quick Look") {
                NSWorkspace.shared.open(file)
            }
        }
    }

    private var composeSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("To", text: $mail.composeTo)
                        .textContentType(.emailAddress)
                    TextField("Cc", text: $mail.composeCc)
                    TextField("Subject", text: $mail.composeSubject)
                }
                Section("Message") {
                    TextField("Write your message…", text: $mail.composeBody, axis: .vertical)
                        .lineLimit(8...20)
                }
                Section("Attachments") {
                    if mail.composeAttachments.isEmpty {
                        Text("Drag files here or use Attach…")
                            .font(Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(mail.composeAttachments, id: \.path) { url in
                        HStack {
                            Image(systemName: "doc")
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                mail.removeComposeAttachment(url)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("Attach…") {
                        pickComposeFiles()
                    }
                }
                if let err = mail.errorMessage {
                    Section {
                        Text(err)
                            .font(Font.caption)
                            .foregroundStyle(Theme.errorText)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { mail.showComposeSheet = false }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Open Draft") {
                        Task { await mail.sendCompose(send: false) }
                    }
                    .disabled(mail.isSending)
                    .help("Open editable draft in Mail.app")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await mail.sendCompose(send: true) }
                    }
                    .disabled(mail.isSending)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleComposeDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if mail.isSending {
                    ProgressView("Sending…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    private func pickComposeFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        mail.addComposeAttachments(panel.urls)
    }

    private func handleComposeDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    } else {
                        url = nil
                    }
                    if let url {
                        DispatchQueue.main.async {
                            mail.addComposeAttachments([url])
                        }
                    }
                }
            }
        }
        return handled
    }

    private func permissionOrError(_ error: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Apple Mail")
                .font(Font.title3.weight(.medium))
            Text(error)
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Refresh") {
                    Task { await mail.refreshAll() }
                }
                .buttonStyle(.borderedProminent)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
            Text("Prodigy shows your Mail.app folders and messages inside the app. Allow Automation → Prodigy → Mail when asked.")
                .font(Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Apple Calendar (in-app)

struct AppleCalendarView: View {
    @ObservedObject var calendar: AppleCalendarService
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header(title: "Calendar", systemImage: "calendar", onClose: onClose) {
                Button {
                    Task { await calendar.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh events")
                .disabled(calendar.isLoading)
            }
            Divider().overlay(Theme.borderHairline)

            if let error = calendar.errorMessage, calendar.events.isEmpty {
                calendarPermissionOrError(error)
            } else {
                HSplitView {
                    eventList
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                    eventDetail
                        .frame(minWidth: 280)
                }
            }
        }
        .background(Theme.centerBackground)
        .task { await calendar.refresh() }
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Next 14 days")
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if calendar.isLoading { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(Theme.borderHairline)

            if calendar.events.isEmpty && !calendar.isLoading {
                Text("No upcoming events.")
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(calendar.events) { event in
                            Button {
                                calendar.selectedID = event.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title)
                                        .font(Font.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2)
                                    Text(timeLine(event))
                                        .font(Font.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(event.calendarName)
                                        .font(Font.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    calendar.selectedID == event.id
                                        ? Theme.selectionFill : Color.clear
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .background(Theme.centerBackground)
    }

    private var eventDetail: some View {
        Group {
            if let event = calendar.selectedEvent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(event.title)
                            .font(Font.title3.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        LabeledContent("When") { Text(timeLine(event)) }
                        LabeledContent("Calendar") { Text(event.calendarName) }
                        if !event.location.isEmpty {
                            LabeledContent("Location") {
                                Text(event.location).textSelection(.enabled)
                            }
                        }
                        if !event.notes.isEmpty {
                            Divider().overlay(Theme.borderHairline)
                            Text(event.notes)
                                .font(Font.body)
                                .textSelection(.enabled)
                        }
                        if let url = event.url {
                            Button("Open link") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Open in Calendar") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select an event")
                    .font(Font.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.centerBackground)
    }

    private func timeLine(_ event: AppleCalendarEvent) -> String {
        if event.isAllDay {
            return "All day · \(event.start.formatted(date: .abbreviated, time: .omitted))"
        }
        let day = event.start.formatted(date: .abbreviated, time: .omitted)
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(start) – \(end)"
    }

    private func calendarPermissionOrError(_ error: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Apple Calendar")
                .font(Font.title3.weight(.medium))
            Text(error)
                .font(Font.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Refresh") {
                    Task { await calendar.refresh() }
                }
                .buttonStyle(.borderedProminent)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Shared header

private func header<Trailing: View>(
    title: String,
    systemImage: String,
    onClose: @escaping () -> Void,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    HStack(spacing: 10) {
        Image(systemName: systemImage)
            .foregroundStyle(Theme.accent)
        Text(title)
            .font(Font.headline)
            .foregroundStyle(Theme.textPrimary)
        Spacer()
        trailing()
        Button(action: onClose) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("Close tab")
    }
    .font(Font.callout)
    .foregroundStyle(Theme.textSecondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Theme.centerBackground)
}
