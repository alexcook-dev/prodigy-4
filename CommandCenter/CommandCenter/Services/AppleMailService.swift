import AppKit
import Foundation

// MARK: - Models

struct AppleMailFolder: Identifiable, Hashable, Sendable {
    /// Stable id: "account||name" (account may be empty for top-level boxes).
    var id: String { "\(account)\u{1e}\(name)" }
    var account: String
    var name: String
    var messageCount: Int

    var displayName: String {
        if account.isEmpty { return name }
        return "\(account)/\(name)"
    }

    var shortName: String { name }
}

struct AppleMailMessage: Identifiable, Hashable, Sendable {
    let id: String
    var subject: String
    var sender: String
    var dateReceived: Date?
    var isRead: Bool
    var preview: String
}

struct AppleMailMessageDetail: Identifiable, Hashable, Sendable {
    let id: String
    var subject: String
    var sender: String
    var dateReceived: Date?
    var isRead: Bool
    /// Plain-text fallback
    var body: String
    /// Rendered HTML document (with styles) for WKWebView
    var htmlDocument: String?
    /// Base URL for relative / file image loads
    var htmlBaseURL: URL?
    /// Exported attachment + inline image files (for chips + drag-out)
    var attachmentFiles: [URL]
}

// MARK: - Script builder

/// AppleScript templates for Mail.app. User strings go through argv or temp files —
/// never spliced into source. Avoid `(read status…)` and variable name `rd`.
enum AppleMailScriptBuilder {
    static let fieldSep = "|||"
    static let bodySep = "<<<PRODIGY_BODY>>>"

    static func launchMailScript() -> String {
        #"""
        tell application "Mail"
          if not running then launch
        end tell
        """#
    }

    /// List account mailboxes. Output lines: account|||mailbox|||count
    static func listFoldersScript() -> String {
        #"""
        on run
          tell application "Mail"
            set output to ""
            repeat with a in accounts
              try
                set an to name of a as string
                repeat with b in mailboxes of a
                  try
                    set nm to name of b as string
                    set cnt to 0
                    try
                      set cnt to (count of messages of b)
                    end try
                    set output to output & an & "|||" & nm & "|||" & cnt & linefeed
                  end try
                end repeat
              end try
            end repeat
            return output
          end tell
        end run
        """#
    }

    /// Messages in a folder.
    /// argv: accountName, mailboxName, limit
    static func folderMessagesScript() -> String {
        #"""
        on run argv
          if (count of argv) < 3 then error "AppleMailScript: need account, mailbox, limit" number 9020
          set accountName to item 1 of argv as string
          set mailboxName to item 2 of argv as string
          set lim to item 3 of argv as integer
          if lim < 1 then set lim to 1
          if lim > 100 then set lim to 100
          tell application "Mail"
            set output to ""
            set boxRef to mailbox mailboxName of account accountName
            set msgCount to (count of messages of boxRef)
            if msgCount is 0 then return ""
            if msgCount < lim then set lim to msgCount
            repeat with i from 1 to lim
              try
                set m to message i of boxRef
                set midVal to (id of m) as string
                set subjVal to (subject of m) as string
                set sndVal to (sender of m) as string
                set drVal to (date received of m) as string
                set rdVal to (get read status of m) as string
                set output to output & midVal & "|||" & subjVal & "|||" & sndVal & "|||" & drVal & "|||" & rdVal & linefeed
              end try
            end repeat
            return output
          end tell
        end run
        """#
    }

    /// Message detail in folder. argv: account, mailbox, messageId
    static func messageDetailScript() -> String {
        #"""
        on run argv
          if (count of argv) < 3 then error "AppleMailScript: need account, mailbox, id" number 9021
          set accountName to item 1 of argv as string
          set mailboxName to item 2 of argv as string
          set midArg to item 3 of argv as string
          set digitCount to 0
          repeat with ch in characters of midArg
            set c to ch as string
            if c is in "0123456789" then set digitCount to digitCount + 1
          end repeat
          if digitCount is not (length of midArg) or (length of midArg) is 0 then
            error "AppleMailScript: message id must be numeric, got: " & midArg number 9003
          end if
          set midNum to midArg as integer
          tell application "Mail"
            set boxRef to mailbox mailboxName of account accountName
            set m to first message of boxRef whose id is midNum
            set midVal to (id of m) as string
            set subjVal to (subject of m) as string
            set sndVal to (sender of m) as string
            set drVal to (date received of m) as string
            set rdVal to (get read status of m) as string
            set bodyText to ""
            try
              set bodyText to (content of m) as string
            end try
            try
              set read status of m to true
            end try
            return midVal & "|||" & subjVal & "|||" & sndVal & "|||" & drVal & "|||" & rdVal & "<<<PRODIGY_BODY>>>" & bodyText
          end tell
        end run
        """#
    }

    /// Reveal. argv: account, mailbox, id
    static func revealScript() -> String {
        #"""
        on run argv
          if (count of argv) < 3 then error "AppleMailScript: need account, mailbox, id" number 9021
          set accountName to item 1 of argv as string
          set mailboxName to item 2 of argv as string
          set midArg to item 3 of argv as string
          set digitCount to 0
          repeat with ch in characters of midArg
            set c to ch as string
            if c is in "0123456789" then set digitCount to digitCount + 1
          end repeat
          if digitCount is not (length of midArg) or (length of midArg) is 0 then
            error "AppleMailScript: message id must be numeric, got: " & midArg number 9003
          end if
          set midNum to midArg as integer
          tell application "Mail"
            activate
            try
              set boxRef to mailbox mailboxName of account accountName
              set theMsg to first message of boxRef whose id is midNum
              open theMsg
            end try
          end tell
        end run
        """#
    }

    /// Reply / reply-all / forward.
    /// argv: account, mailbox, messageId, bodyFilePath, mode, sendFlag
    static func respondScript() -> String {
        #"""
        on run argv
          if (count of argv) < 6 then error "AppleMailScript: need account, mailbox, id, bodyPath, mode, sendFlag" number 9010
          set accountName to item 1 of argv as string
          set mailboxName to item 2 of argv as string
          set midArg to item 3 of argv as string
          set bodyPath to item 4 of argv as string
          set modeName to item 5 of argv as string
          set sendFlag to item 6 of argv as string
          set digitCount to 0
          repeat with ch in characters of midArg
            set c to ch as string
            if c is in "0123456789" then set digitCount to digitCount + 1
          end repeat
          if digitCount is not (length of midArg) or (length of midArg) is 0 then
            error "AppleMailScript: message id must be numeric, got: " & midArg number 9003
          end if
          set midNum to midArg as integer
          set replyText to do shell script "/bin/cat " & quoted form of bodyPath
          set doSend to (sendFlag is "1")
          tell application "Mail"
            set boxRef to mailbox mailboxName of account accountName
            set orig to first message of boxRef whose id is midNum
            if modeName is "replyAll" then
              set outMsg to reply orig with reply to all without opening window
            else if modeName is "forward" then
              set outMsg to forward orig without opening window
            else
              set outMsg to reply orig without opening window
            end if
            set oldContent to ""
            try
              set oldContent to content of outMsg as string
            end try
            if replyText is "" then
              set content of outMsg to oldContent
            else
              set content of outMsg to replyText & return & return & oldContent
            end if
            if doSend then
              send outMsg
              return "sent"
            else
              set visible of outMsg to true
              activate
              return "draft"
            end if
          end tell
        end run
        """#
    }

    /// Compose new.
    /// argv: toFile, subjectFile, bodyFile, sendFlag [, ccFile [, attachmentsListFile]]
    /// attachmentsListFile: one absolute path per line.
    static func composeScript() -> String {
        #"""
        on run argv
          if (count of argv) < 4 then error "AppleMailScript: need to, subject, body, sendFlag" number 9011
          set toPath to item 1 of argv as string
          set subjectPath to item 2 of argv as string
          set bodyPath to item 3 of argv as string
          set sendFlag to item 4 of argv as string
          set toLine to do shell script "/bin/cat " & quoted form of toPath
          set subjectText to do shell script "/bin/cat " & quoted form of subjectPath
          set bodyText to do shell script "/bin/cat " & quoted form of bodyPath
          set ccLine to ""
          set attListPath to ""
          if (count of argv) >= 5 then
            set ccPath to item 5 of argv as string
            if ccPath is not "" then set ccLine to do shell script "/bin/cat " & quoted form of ccPath
          end if
          if (count of argv) >= 6 then
            set attListPath to item 6 of argv as string
          end if
          set doSend to (sendFlag is "1")
          tell application "Mail"
            set outMsg to make new outgoing message with properties {subject:subjectText, content:bodyText, visible:(not doSend)}
            set AppleScript's text item delimiters to {",", ";"}
            set toParts to text items of toLine
            set AppleScript's text item delimiters to ""
            repeat with part in toParts
              set addr to my trim(part as string)
              if addr is not "" then
                make new to recipient at end of to recipients of outMsg with properties {address:addr}
              end if
            end repeat
            if ccLine is not "" then
              set AppleScript's text item delimiters to {",", ";"}
              set ccParts to text items of ccLine
              set AppleScript's text item delimiters to ""
              repeat with part in ccParts
                set addr to my trim(part as string)
                if addr is not "" then
                  make new cc recipient at end of cc recipients of outMsg with properties {address:addr}
                end if
              end repeat
            end if
            if attListPath is not "" then
              set attText to do shell script "/bin/cat " & quoted form of attListPath
              repeat with lineText in paragraphs of attText
                set pth to my trim(lineText as string)
                if pth is not "" then
                  try
                    tell content of outMsg
                      make new attachment with properties {file name:POSIX file pth} at after the last paragraph
                    end tell
                  end try
                end if
              end repeat
            end if
            if doSend then
              send outMsg
              return "sent"
            else
              set visible of outMsg to true
              activate
              return "draft"
            end if
          end tell
        end run

        on trim(t)
          set t to t as string
          repeat while t starts with " " or t starts with tab
            if length of t is 0 then exit repeat
            set t to text 2 thru -1 of t
          end repeat
          repeat while t ends with " " or t ends with tab
            if length of t is 0 then exit repeat
            set t to text 1 thru -2 of t
          end repeat
          return t
        end trim
        """#
    }

    /// Save raw RFC822 source to a path (written by AppleScript, not Mail "save attachment").
    /// argv: account, mailbox, id, destPath
    static func saveSourceScript() -> String {
        #"""
        on run argv
          if (count of argv) < 4 then error "AppleMailScript: need account, mailbox, id, dest" number 9030
          set accountName to item 1 of argv as string
          set mailboxName to item 2 of argv as string
          set midArg to item 3 of argv as string
          set destPath to item 4 of argv as string
          set digitCount to 0
          repeat with ch in characters of midArg
            set c to ch as string
            if c is in "0123456789" then set digitCount to digitCount + 1
          end repeat
          if digitCount is not (length of midArg) or (length of midArg) is 0 then
            error "AppleMailScript: message id must be numeric" number 9003
          end if
          set midNum to midArg as integer
          tell application "Mail"
            set boxRef to mailbox mailboxName of account accountName
            set m to first message of boxRef whose id is midNum
            set src to source of m as string
          end tell
          set f to open for access (POSIX file destPath) with write permission
          set eof of f to 0
          write src to f as «class utf8»
          close access f
          return destPath
        end run
        """#
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\" & return & \"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\" & linefeed & \"")
        return "\"\(escaped)\""
    }

    static func validateScriptSource(_ source: String) throws {
        let forbidden = ["(read status", "(read "]
        for token in forbidden {
            if source.contains(token) {
                throw AppleMailError.scriptGenerationFailed(
                    offendingValue: token,
                    detail: "Forbidden form \(token)… — use “get read status of m”."
                )
            }
        }
        if source.range(of: #"\bset\s+rd\s+to\b"#, options: .regularExpression) != nil {
            throw AppleMailError.scriptGenerationFailed(
                offendingValue: "set rd to",
                detail: "Variable name “rd” is banned (-2741). Use “rdVal”."
            )
        }
    }
}

// MARK: - Service

@MainActor
final class AppleMailService: ObservableObject {
    static let shared = AppleMailService()

    @Published var folders: [AppleMailFolder] = []
    @Published var selectedFolderID: String?
    @Published var messages: [AppleMailMessage] = []
    @Published var selectedID: String?
    @Published var detail: AppleMailMessageDetail?
    @Published var isLoadingFolders = false
    @Published var isLoadingList = false
    @Published var isLoadingDetail = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    @Published var responseDraft: String = ""
    @Published var responseMode: MailResponseMode = .reply

    @Published var composeTo: String = ""
    @Published var composeCc: String = ""
    @Published var composeSubject: String = ""
    @Published var composeBody: String = ""
    @Published var composeAttachments: [URL] = []
    @Published var showComposeSheet = false

    enum MailResponseMode: String, CaseIterable, Identifiable {
        case reply, replyAll, forward
        var id: String { rawValue }
        var title: String {
            switch self {
            case .reply: return "Reply"
            case .replyAll: return "Reply All"
            case .forward: return "Forward"
            }
        }
        var scriptMode: String { rawValue }
    }

    var selectedFolder: AppleMailFolder? {
        folders.first { $0.id == selectedFolderID }
    }

    var selectedMessage: AppleMailMessage? {
        messages.first { $0.id == selectedID }
    }

    // MARK: - Public API

    func refreshAll() async {
        await refreshFolders()
        if selectedFolder != nil {
            await refreshMessages()
        }
    }

    func refreshFolders() async {
        isLoadingFolders = true
        errorMessage = nil
        defer { isLoadingFolders = false }
        do {
            try await launchMailIfNeeded()
            let raw = try await runAppleScript(
                AppleMailScriptBuilder.listFoldersScript(),
                arguments: [],
                label: "folders"
            )
            folders = parseFolders(raw).sorted { a, b in
                // Inbox first within account, then alpha.
                folderSortKey(a) < folderSortKey(b)
            }
            if selectedFolderID == nil || !folders.contains(where: { $0.id == selectedFolderID }) {
                // Prefer Inbox
                if let inbox = folders.first(where: {
                    $0.name.localizedCaseInsensitiveCompare("Inbox") == .orderedSame
                }) {
                    selectedFolderID = inbox.id
                } else {
                    selectedFolderID = folders.first?.id
                }
            }
            if selectedFolder != nil {
                await refreshMessages()
            }
        } catch {
            errorMessage = error.localizedDescription
            folders = []
        }
    }

    func selectFolder(_ folder: AppleMailFolder) async {
        selectedFolderID = folder.id
        selectedID = nil
        detail = nil
        messages = []
        await refreshMessages()
    }

    func refreshMessages(limit: Int = 50) async {
        guard let folder = selectedFolder else {
            messages = []
            return
        }
        isLoadingList = true
        errorMessage = nil
        defer { isLoadingList = false }
        do {
            try await launchMailIfNeeded()
            let lim = max(1, min(limit, 100))
            let raw = try await runAppleScript(
                AppleMailScriptBuilder.folderMessagesScript(),
                arguments: [folder.account, folder.name, "\(lim)"],
                label: "folder-messages"
            )
            messages = parseMessages(raw)
            if selectedID == nil || !messages.contains(where: { $0.id == selectedID }) {
                selectedID = messages.first?.id
            }
            if let id = selectedID {
                await loadDetail(id: id)
            } else {
                detail = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            messages = []
            detail = nil
        }
    }

    func select(_ id: String) async {
        selectedID = id
        await loadDetail(id: id)
    }

    func loadDetail(id: String) async {
        guard let folder = selectedFolder else { return }
        isLoadingDetail = true
        errorMessage = nil
        defer { isLoadingDetail = false }
        do {
            let safeID = id.filter(\.isNumber)
            guard !safeID.isEmpty else { throw AppleMailError.parseFailed }
            let raw = try await runAppleScript(
                AppleMailScriptBuilder.messageDetailScript(),
                arguments: [folder.account, folder.name, safeID],
                label: "message-detail"
            )
            var parsed = try parseDetail(raw)
            // HTML + images via RFC822 source (attachments exported beside HTML).
            if let pkg = try? await renderHTMLPackage(
                account: folder.account,
                mailbox: folder.name,
                messageID: safeID
            ) {
                parsed.htmlDocument = pkg.htmlDocument
                parsed.htmlBaseURL = pkg.baseURL
                parsed.attachmentFiles = pkg.attachments.map(\.url)
                if parsed.body.isEmpty || parsed.body == "(empty message)",
                   let plain = pkg.plainText, !plain.isEmpty {
                    parsed.body = plain
                }
            }
            detail = parsed
            if let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].isRead = true
            }
        } catch {
            errorMessage = error.localizedDescription
            detail = nil
        }
    }

    /// Export a message attachment (or any rendered part file) into a Prodigy folder.
    func copyAttachments(_ urls: [URL], toDirectory directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls {
            let dest = directory.appendingPathComponent(url.lastPathComponent)
            let final = uniqueDest(dest)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.copyItem(at: url, to: final)
            }
        }
    }

    private func uniqueDest(_ dest: URL) -> URL {
        if !FileManager.default.fileExists(atPath: dest.path) { return dest }
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var i = 2
        var candidate: URL
        repeat {
            let name = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            candidate = dest.deletingLastPathComponent().appendingPathComponent(name)
            i += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private func renderHTMLPackage(
        account: String,
        mailbox: String,
        messageID: String
    ) async throws -> MailMIMEHTML.RenderPackage {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("prodigy-mail-render-\(messageID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let eml = work.appendingPathComponent("message.eml")
        _ = try await runAppleScript(
            AppleMailScriptBuilder.saveSourceScript(),
            arguments: [account, mailbox, messageID, eml.path],
            label: "save-source"
        )
        let data = try Data(contentsOf: eml)
        return try MailMIMEHTML.buildRenderPackage(sourceData: data, workDir: work)
    }

    func revealInMailApp(id: String) async {
        guard let folder = selectedFolder else { return }
        let safeID = id.filter(\.isNumber)
        guard !safeID.isEmpty else { return }
        _ = try? await runAppleScript(
            AppleMailScriptBuilder.revealScript(),
            arguments: [folder.account, folder.name, safeID],
            label: "reveal"
        )
    }

    func beginCompose(to: String = "", subject: String = "", body: String = "") {
        composeTo = to
        composeCc = ""
        composeSubject = subject
        composeBody = body
        composeAttachments = []
        showComposeSheet = true
        errorMessage = nil
        statusMessage = nil
    }

    func addComposeAttachments(_ urls: [URL]) {
        let existing = Set(composeAttachments.map(\.path))
        for url in urls {
            let resolved = url.standardizedFileURL
            guard !existing.contains(resolved.path) else { continue }
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }
            composeAttachments.append(resolved)
        }
    }

    func removeComposeAttachment(_ url: URL) {
        composeAttachments.removeAll { $0.path == url.path }
    }

    func respondToSelected(send: Bool) async {
        guard let folder = selectedFolder, let id = selectedID else {
            errorMessage = "Select a folder and message first."
            return
        }
        let safeID = id.filter(\.isNumber)
        guard !safeID.isEmpty else {
            errorMessage = "Invalid message id."
            return
        }
        isSending = true
        errorMessage = nil
        statusMessage = nil
        defer { isSending = false }
        do {
            try await launchMailIfNeeded()
            let bodyURL = try writeTempText(responseDraft, label: "reply-body")
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            let result = try await runAppleScript(
                AppleMailScriptBuilder.respondScript(),
                arguments: [
                    folder.account,
                    folder.name,
                    safeID,
                    bodyURL.path,
                    responseMode.scriptMode,
                    send ? "1" : "0",
                ],
                label: "respond-\(responseMode.rawValue)"
            )
            if send {
                statusMessage = "\(responseMode.title) sent."
                responseDraft = ""
                await refreshMessages()
            } else {
                statusMessage = result.trimmingCharacters(in: .whitespacesAndNewlines) == "draft"
                    ? "Draft opened in Mail."
                    : "Opened in Mail."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendCompose(send: Bool) async {
        let to = composeTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else {
            errorMessage = "Add at least one recipient in To."
            return
        }
        isSending = true
        errorMessage = nil
        statusMessage = nil
        defer { isSending = false }
        do {
            try await launchMailIfNeeded()
            let toURL = try writeTempText(to, label: "compose-to")
            let subjectURL = try writeTempText(composeSubject, label: "compose-subject")
            let bodyURL = try writeTempText(composeBody, label: "compose-body")
            let ccTrimmed = composeCc.trimmingCharacters(in: .whitespacesAndNewlines)
            let ccURL = try writeTempText(ccTrimmed, label: "compose-cc")
            // Always pass cc slot (may be empty) so attachments stay argv[6]
            let attList = composeAttachments.map(\.path).joined(separator: "\n")
            let attURL = try writeTempText(attList, label: "compose-atts")
            defer {
                try? FileManager.default.removeItem(at: toURL)
                try? FileManager.default.removeItem(at: subjectURL)
                try? FileManager.default.removeItem(at: bodyURL)
                try? FileManager.default.removeItem(at: ccURL)
                try? FileManager.default.removeItem(at: attURL)
            }
            let args = [
                toURL.path,
                subjectURL.path,
                bodyURL.path,
                send ? "1" : "0",
                ccURL.path,
                composeAttachments.isEmpty ? "" : attURL.path,
            ]
            let result = try await runAppleScript(
                AppleMailScriptBuilder.composeScript(),
                arguments: args,
                label: "compose"
            )
            if send {
                statusMessage = "Message sent."
                showComposeSheet = false
                composeTo = ""
                composeCc = ""
                composeSubject = ""
                composeBody = ""
                composeAttachments = []
            } else {
                statusMessage = result.trimmingCharacters(in: .whitespacesAndNewlines) == "draft"
                    ? "Draft opened in Mail."
                    : "Opened in Mail."
                showComposeSheet = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Parse

    private func parseFolders(_ raw: String) -> [AppleMailFolder] {
        raw.split(whereSeparator: \.isNewline).compactMap { lineSub in
            let cols = String(lineSub).components(separatedBy: "|||")
            guard cols.count >= 2 else { return nil }
            let account = cols[0]
            let name = cols[1]
            guard !name.isEmpty else { return nil }
            let count = cols.count >= 3 ? (Int(cols[2]) ?? 0) : 0
            return AppleMailFolder(account: account, name: name, messageCount: count)
        }
    }

    private func folderSortKey(_ f: AppleMailFolder) -> String {
        let priority: String
        switch f.name.lowercased() {
        case "inbox": priority = "0"
        case "drafts", "draft": priority = "1"
        case "sent items", "sent": priority = "2"
        case "archive": priority = "3"
        case "deleted items", "trash": priority = "4"
        case "junk email", "junk", "spam": priority = "5"
        default: priority = "9"
        }
        return "\(f.account.lowercased())|\(priority)|\(f.name.lowercased())"
    }

    private func parseMessages(_ raw: String) -> [AppleMailMessage] {
        raw.split(whereSeparator: \.isNewline).compactMap { lineSub in
            let cols = String(lineSub).components(separatedBy: "|||")
            guard cols.count >= 5 else { return nil }
            return AppleMailMessage(
                id: cols[0],
                subject: cols[1].isEmpty ? "(no subject)" : cols[1],
                sender: cols[2],
                dateReceived: parseMailDate(cols[3]),
                isRead: cols[4].lowercased().contains("true"),
                preview: ""
            )
        }
    }

    private func parseDetail(_ raw: String) throws -> AppleMailMessageDetail {
        guard let range = raw.range(of: AppleMailScriptBuilder.bodySep) else {
            throw AppleMailError.parseFailed
        }
        let header = String(raw[..<range.lowerBound])
        let body = String(raw[range.upperBound...])
        let cols = header.components(separatedBy: AppleMailScriptBuilder.fieldSep)
        guard cols.count >= 5 else { throw AppleMailError.parseFailed }
        return AppleMailMessageDetail(
            id: cols[0],
            subject: cols[1].isEmpty ? "(no subject)" : cols[1],
            sender: cols[2],
            dateReceived: parseMailDate(cols[3]),
            isRead: cols[4].lowercased().contains("true"),
            body: body.isEmpty ? "(empty message)" : body,
            htmlDocument: nil,
            htmlBaseURL: nil,
            attachmentFiles: []
        )
    }

    private func parseMailDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm:ss a",
            "EEEE, MMMM d, yyyy at h:mm:ss a",
            "MMM d, yyyy 'at' h:mm:ss a",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "MM/dd/yyyy, h:mm:ss a",
            "M/d/yy, h:mm:ss a",
        ]
        let f = DateFormatter()
        f.locale = Locale.current
        for pattern in formats {
            f.dateFormat = pattern
            if let d = f.date(from: trimmed) { return d }
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = detector?.firstMatch(in: trimmed, range: range), let date = match.date {
            return date
        }
        return nil
    }

    private func writeTempText(_ text: String, label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prodigy-mail-\(label)-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Runner

    private func launchMailIfNeeded() async throws {
        _ = try await runAppleScript(
            AppleMailScriptBuilder.launchMailScript(),
            arguments: [],
            label: "launch"
        )
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func runAppleScript(
        _ source: String,
        arguments: [String],
        label: String
    ) async throws -> String {
        try AppleMailScriptBuilder.validateScriptSource(source)

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let dir = FileManager.default.temporaryDirectory
                    let url = dir.appendingPathComponent(
                        "prodigy-mail-\(label)-\(UUID().uuidString).scpt.txt"
                    )
                    try source.write(to: url, atomically: true, encoding: .utf8)

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = [url.path] + arguments
                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    try process.run()
                    process.waitUntilExit()

                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: data, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let stable = dir.appendingPathComponent("prodigy-mail-last-failure.scpt.txt")
                        try? FileManager.default.removeItem(at: stable)
                        try? FileManager.default.copyItem(at: url, to: stable)
                        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = msg.lowercased()
                        if lower.contains("not allowed")
                            || lower.contains("not authorized")
                            || lower.contains("(-1743)")
                            || lower.contains("1002") {
                            try? FileManager.default.removeItem(at: url)
                            cont.resume(throwing: AppleMailError.automationDenied)
                        } else if lower.contains("syntax") || lower.contains("-2741") {
                            cont.resume(throwing: AppleMailError.scriptCompileFailed(
                                path: stable.path,
                                osascriptMessage: msg,
                                sourceSnippet: String(source.prefix(120)),
                                arguments: arguments
                            ))
                        } else {
                            try? FileManager.default.removeItem(at: url)
                            cont.resume(throwing: AppleMailError.scriptFailed(
                                msg.isEmpty
                                    ? "Mail scripting failed (code \(process.terminationStatus))."
                                    : msg
                            ))
                        }
                        return
                    }
                    try? FileManager.default.removeItem(at: url)
                    cont.resume(returning: stdout)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

enum AppleMailError: LocalizedError {
    case automationDenied
    case scriptFailed(String)
    case parseFailed
    case scriptGenerationFailed(offendingValue: String, detail: String)
    case scriptCompileFailed(
        path: String,
        osascriptMessage: String,
        sourceSnippet: String,
        arguments: [String]
    )

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return "Prodigy needs permission to control Mail. System Settings → Privacy & Security → Automation → enable Mail for Prodigy, then refresh."
        case .scriptFailed(let s):
            return s
        case .parseFailed:
            return "Could not read that message from Mail."
        case .scriptGenerationFailed(let value, let detail):
            return "Mail script generation failed (value: \(value)). \(detail)"
        case .scriptCompileFailed(let path, let msg, let snippet, let args):
            return "Mail AppleScript compile error: \(msg)\nNear: \(snippet)\nArgs: \(args)\nScript: \(path)"
        }
    }
}
