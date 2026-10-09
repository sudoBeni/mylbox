import Foundation

/// Mirrors the mails of a space into a folder (usually inside another project's repository) as Markdown,
/// so that tools and AI assistants working in that project have the full mail context.
///
/// Layout:
///   README.md              what this folder is
///   INDEX.md               all threads, newest first
///   messages/<date>_<slug>_<key>.md
///   attachments/<key>/<filename>
///   .mylbox-export.json    files written by mylbox (stale ones are removed)
public enum ExportError: LocalizedError {
    case folderNotEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .folderNotEmpty(let path):
            "\(path) already contains files that mylbox did not create. Choose an empty folder, e.g. a new \"mail\" subfolder."
        }
    }
}

public enum SpaceExporter {
    public struct Result: Sendable {
        public var written = 0
        public var removed = 0
        public var total = 0
    }

    private struct Manifest: Codable {
        var space: String
        var files: [String]
    }

    public static func export(space: Space, messages: [MailMessage], accounts: [Account]) throws -> Result {
        guard let path = space.exportFolder, !path.isEmpty else { return Result() }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let fileManager = FileManager.default
        let manifestURL = root.appendingPathComponent(".mylbox-export.json")

        // Never write into a folder that has content mylbox did not create (e.g. a repository root).
        if !fileManager.fileExists(atPath: manifestURL.path),
           let existing = try? fileManager.contentsOfDirectory(atPath: root.path),
           existing.contains(where: { $0 != ".DS_Store" }) {
            throw ExportError.folderNotEmpty(root.path)
        }
        try Paths.ensure(root.appendingPathComponent("messages", isDirectory: true))

        let previous = (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)))?.files ?? []

        var result = Result()
        var files: [String] = ["README.md", "INDEX.md"]
        let sorted = messages.sorted { $0.date < $1.date }
        // The same mail can exist twice (e.g. in Inbox and Sent when writing to yourself).
        var seen = Set<String>()
        var entries: [(message: MailMessage, file: String)] = []

        for message in sorted where seen.insert(message.stableKey).inserted {
            let file = "messages/\(fileStem(message)).md"
            var attachmentFiles: [String] = []
            if space.includeAttachments, !message.attachments.isEmpty {
                attachmentFiles = try writeAttachments(message, root: root)
                files += attachmentFiles
            }
            let markdown = render(message, attachments: attachmentFiles, accounts: accounts)
            let url = root.appendingPathComponent(file)
            if (try? String(contentsOf: url, encoding: .utf8)) != markdown {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                result.written += 1
            }
            files.append(file)
            entries.append((message, file))
        }

        try readme(space).write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try index(space, entries).write(to: root.appendingPathComponent("INDEX.md"), atomically: true, encoding: .utf8)

        let gitignore = root.appendingPathComponent(".gitignore")
        if space.keepOutOfGit {
            try "# Written by mylbox: keep mails out of git\n*\n".write(to: gitignore, atomically: true, encoding: .utf8)
            files.append(".gitignore")
        } else if previous.contains(".gitignore") {
            try? fileManager.removeItem(at: gitignore)
        }

        let current = Set(files)
        for stale in previous where !current.contains(stale) {
            if (try? fileManager.removeItem(at: root.appendingPathComponent(stale))) != nil { result.removed += 1 }
        }
        removeEmptyDirectories(in: root.appendingPathComponent("attachments", isDirectory: true))

        let manifest = Manifest(space: space.name, files: files.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        result.total = entries.count
        return result
    }

    // MARK: Files

    static func fileStem(_ message: MailMessage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(formatter.string(from: message.date))_\(slug(message.subject))_\(message.stableKey)"
    }

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        var slug = ""
        var lastWasDash = false
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
            if slug.count >= 50 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "no-subject" : slug
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "attachment\(cleaned)" : cleaned
    }

    private static func writeAttachments(_ message: MailMessage, root: URL) throws -> [String] {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: message.rawPath)) else { return [] }
        let parsed = MIME.parse(raw)
        var paths: [String] = []
        var used = Set<String>()
        for attachment in parsed.attachments where !attachment.isInline {
            var name = safeFilename(attachment.filename)
            var counter = 2
            while !used.insert(name).inserted {
                name = "\(counter)-\(safeFilename(attachment.filename))"
                counter += 1
            }
            let relative = "attachments/\(message.stableKey)/\(name)"
            let url = root.appendingPathComponent(relative)
            try Paths.ensure(url.deletingLastPathComponent())
            if (try? Data(contentsOf: url)) != attachment.data {
                try attachment.data.write(to: url, options: .atomic)
            }
            paths.append(relative)
        }
        return paths
    }

    private static func removeEmptyDirectories(in directory: URL) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for child in children where (try? fileManager.contentsOfDirectory(atPath: child.path))?.isEmpty == true {
            try? fileManager.removeItem(at: child)
        }
    }

    // MARK: Rendering

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private static func yaml(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    static func render(_ message: MailMessage, attachments: [String], accounts: [Account]) -> String {
        let account = accounts.first { $0.id == message.accountID }?.email ?? ""
        var lines = ["---"]
        lines.append("subject: \(yaml(message.subject))")
        lines.append("from: \(yaml(message.from.formatted))")
        lines.append("to: [\(message.to.map { yaml($0.formatted) }.joined(separator: ", "))]")
        if !message.cc.isEmpty { lines.append("cc: [\(message.cc.map { yaml($0.formatted) }.joined(separator: ", "))]") }
        lines.append("date: \(isoFormatter.string(from: message.date))")
        lines.append("direction: \(message.folderRole == .sent ? "sent" : "received")")
        lines.append("account: \(yaml(account))")
        if !message.messageID.isEmpty { lines.append("message_id: \(yaml(message.messageID))") }
        if !message.inReplyTo.isEmpty { lines.append("in_reply_to: \(yaml(message.inReplyTo))") }
        lines.append("thread: \(yaml(threadSubject(message.subject)))")
        if let summary = message.summary, !summary.isEmpty { lines.append("summary: \(yaml(summary))") }
        if !attachments.isEmpty {
            lines.append("attachments:")
            lines += attachments.map { "  - \(yaml("../" + $0))" }
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(message.subject.isEmpty ? "(no subject)" : message.subject)")
        lines.append("")
        lines.append("- **From:** \(message.from.formatted)")
        lines.append("- **To:** \(message.to.map(\.formatted).joined(separator: ", "))")
        if !message.cc.isEmpty { lines.append("- **Cc:** \(message.cc.map(\.formatted).joined(separator: ", "))") }
        lines.append("- **Date:** \(message.date.formatted(date: .complete, time: .shortened))")
        if !attachments.isEmpty {
            let links = attachments.map { "[\(($0 as NSString).lastPathComponent)](../\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0))" }
            lines.append("- **Attachments:** \(links.joined(separator: ", "))")
        }
        lines.append("")
        let body = message.bodyText.isEmpty ? message.bodyHTML.map(HTMLText.plainText) ?? "" : message.bodyText
        lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func threadSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "aw:", "fwd:", "fw:", "wg:", "antw:", "tr:", "rif:", "sv:", "vs:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return result.isEmpty ? "(no subject)" : result
    }

    static func index(_ space: Space, _ entries: [(message: MailMessage, file: String)]) -> String {
        let threads = Dictionary(grouping: entries) { threadSubject($0.message.subject).lowercased() }
            .values
            .sorted { ($0.map(\.message.date).max() ?? .distantPast) > ($1.map(\.message.date).max() ?? .distantPast) }
        var lines = ["# \(space.name): mail index", "",
                     "\(entries.count) mails in \(threads.count) threads. Newest thread first; mails inside a thread oldest first.",
                     ""]
        for thread in threads {
            let subject = threadSubject(thread[0].message.subject)
            lines.append("## \(subject)")
            lines.append("")
            for entry in thread.sorted(by: { $0.message.date < $1.message.date }) {
                let date = entry.message.date.formatted(.iso8601.year().month().day())
                let arrow = entry.message.folderRole == .sent ? "→ sent to \(entry.message.to.first?.displayName ?? "")"
                                                            : "← \(entry.message.from.displayName)"
                let clip = entry.message.attachments.isEmpty ? "" : " 📎"
                lines.append("- \(date) \(arrow): [\(entry.message.subject.isEmpty ? "(no subject)" : entry.message.subject)](\(entry.file))\(clip)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func readme(_ space: Space) -> String {
        """
        # Mail: \(space.name)

        This folder is generated by **mylbox** and mirrors all mails in the space "\(space.name)".
        It is updated automatically after every sync. Do not edit files here; changes are overwritten.

        - `INDEX.md`: all conversations (threads), newest first, with links to each mail.
        - `messages/`: one Markdown file per mail. The YAML front matter holds sender, recipients,
          date, direction (received/sent), thread and attachments; the body follows below.
        - `attachments/<key>/`: the attachments of the mail whose file name ends in `<key>`.

        To find something, search `messages/` (for example by sender or subject) or start from `INDEX.md`.
        To add or remove mails, change the space or its rules in mylbox.

        """
    }
}
