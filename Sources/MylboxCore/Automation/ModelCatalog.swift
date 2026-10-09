import CryptoKit
import Foundation

public struct LocalModelInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var url: URL
    public var sha256: String
    public var size: Int64

    public var fileURL: URL { Paths.models.appendingPathComponent(url.lastPathComponent) }
    public var isDownloaded: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
}

public enum LocalModelCatalog {
    public static let models: [LocalModelInfo] = [
        LocalModelInfo(
            id: "qwen2.5-1.5b",
            name: "Qwen2.5 1.5B (recommended)",
            detail: "1.1 GB · about 1 second per mail, sorted 6 of 6 test mails correctly",
            url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
            size: 1_117_320_736),
        LocalModelInfo(
            id: "qwen2.5-3b",
            name: "Qwen2.5 3B",
            detail: "2.1 GB · larger and slower, sorted 5 of 6 test mails correctly",
            url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
            sha256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d",
            size: 2_104_932_768),
    ]

    public static var defaultModel: LocalModelInfo { models[0] }

    public static func model(_ id: String) -> LocalModelInfo {
        models.first { $0.id == id } ?? defaultModel
    }
}

/// Downloads a model file, reports progress and verifies its SHA-256 before using it.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let info: LocalModelInfo
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    public init(_ info: LocalModelInfo, progress: @escaping @Sendable (Double) -> Void) {
        self.info = info
        self.progress = progress
    }

    public func download() async throws {
        try Paths.ensure(Paths.models)
        let temporary: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                self.session = session
                session.downloadTask(with: info.url).resume()
            }
        } onCancel: {
            self.session?.invalidateAndCancel()
        }
        progress(1)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard try Self.sha256(of: temporary) == info.sha256 else {
            throw LocalModelError(message: "the download is damaged (checksum mismatch), please try again")
        }
        try? FileManager.default.removeItem(at: info.fileURL)
        try FileManager.default.moveItem(at: temporary, to: info.fileURL)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : info.size
        progress(min(0.99, Double(totalBytesWritten) / Double(total)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this method returns, so move it first.
        let kept = Paths.models.appendingPathComponent(UUID().uuidString + ".part")
        do {
            if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
                throw LocalModelError(message: "download failed (HTTP \(response.statusCode))")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
