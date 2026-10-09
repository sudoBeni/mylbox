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
    // Benchmarked on 16 German, Swiss German, French and English test mails (see LocalModelTests).
    // Files come from Unsloth's GGUF builds and are pinned by SHA-256.
    public static let models: [LocalModelInfo] = [
        LocalModelInfo(
            id: "qwen3.5-4b",
            name: "Qwen3.5 4B (recommended)",
            detail: "2.7 GB · sorted 15 of 16 test mails correctly, about 2 seconds per mail",
            url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
            sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
            size: 2_740_937_888),
        LocalModelInfo(
            id: "qwen3.5-2b",
            name: "Qwen3.5 2B (light)",
            detail: "1.3 GB · sorted 13 of 16 test mails correctly, about 1 second per mail",
            url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!,
            sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
            size: 1_280_835_840),
    ]

    public static var defaultModel: LocalModelInfo { models[0] }

    public static func model(_ id: String) -> LocalModelInfo {
        models.first { $0.id == id } ?? defaultModel
    }

    /// Deletes model files that are no longer offered (e.g. after switching to a newer model generation).
    public static func removeUnusedFiles() {
        let known = Set(models.map { $0.fileURL.lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        for file in files where !known.contains(file) {
            try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(file))
        }
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
