import CryptoKit
import Foundation

public enum Paths {
    public static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["RALLYMAIL_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("RallyMail", isDirectory: true)
        migrateLegacyFolder(from: base.appendingPathComponent("mylbox", isDirectory: true), to: current)
        return current
    }

    public static var database: URL { appSupport.appendingPathComponent("rallymail.sqlite") }
    public static var config: URL { appSupport.appendingPathComponent("config.json") }

    public static var models: URL { appSupport.appendingPathComponent("models", isDirectory: true) }

    public static func rawDirectory(account: UUID) -> URL {
        appSupport.appendingPathComponent("raw/\(account.uuidString)", isDirectory: true)
    }

    public static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The app used to be called mylbox. Its data folder is moved over once, the first time RallyMail starts.
    private static func migrateLegacyFolder(from old: URL, to new: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { return }
        try? fileManager.moveItem(at: old, to: new)
        let oldDatabase = new.appendingPathComponent("mylbox.sqlite")
        if fileManager.fileExists(atPath: oldDatabase.path) {
            try? fileManager.moveItem(at: oldDatabase, to: new.appendingPathComponent("rallymail.sqlite"))
        }
    }
}

public enum StableHash {
    public static func hex(_ string: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}

public final class ConfigStore: @unchecked Sendable {
    private let url: URL

    public init(url: URL = Paths.config) {
        self.url = url
    }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it with an empty config on the next save.
            let backup = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return AppConfig()
        }
    }

    public func save(_ config: AppConfig) throws {
        try Paths.ensure(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
