import Foundation
import NIOCore
import NIOPosix
import NIOSSL

public enum ConnectionError: LocalizedError {
    case closed
    case timeout
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .closed: "The server closed the connection."
        case .timeout: "The server did not answer in time."
        case .protocolError(let message): message
        }
    }
}

private enum StreamEvent: Sendable {
    case data(ByteBuffer)
    case closed
    case failed(Error)
}

private final class StreamHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let continuation: AsyncStream<StreamEvent>.Continuation

    init(continuation: AsyncStream<StreamEvent>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(.data(unwrapInboundIn(data)))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.yield(.closed)
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.yield(.failed(error))
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            continuation.yield(.failed(ConnectionError.timeout))
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// A byte stream over TCP (optionally TLS) with line-oriented reading, used by IMAP and SMTP.
/// Not safe for concurrent use: one connection belongs to one task.
public final class TextConnection: @unchecked Sendable {
    private let channel: Channel
    private let host: String
    private var iterator: AsyncStream<StreamEvent>.AsyncIterator
    private var buffer: [UInt8] = []
    private var readIndex = 0

    private init(channel: Channel, host: String, stream: AsyncStream<StreamEvent>) {
        self.channel = channel
        self.host = host
        self.iterator = stream.makeAsyncIterator()
    }

    public static func connect(host: String, port: Int, tls: Bool, timeout: TimeAmount = .seconds(90)) async throws -> TextConnection {
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(20))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if tls {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: sslContext, serverHostname: host))
                    }
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: timeout))
                    try channel.pipeline.syncOperations.addHandler(StreamHandler(continuation: continuation))
                }
            }
        let channel = try await bootstrap.connect(host: host, port: port).get()
        return TextConnection(channel: channel, host: host, stream: stream)
    }

    /// Upgrades the plain connection to TLS (after a successful STARTTLS command).
    public func startTLS() async throws {
        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
        let host = self.host
        let channel = self.channel
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(
                NIOSSLClientHandler(context: sslContext, serverHostname: host), position: .first)
        }.get()
    }

    public func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    public func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    /// Reads one line, without the trailing CRLF.
    public func readLine() async throws -> [UInt8] {
        var searchFrom = readIndex
        while true {
            if let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
                var end = newline
                if end > readIndex, buffer[end - 1] == 0x0D { end -= 1 }
                let line = Array(buffer[readIndex..<end])
                readIndex = newline + 1
                compact()
                return line
            }
            searchFrom = buffer.count
            try await fill()
        }
    }

    public func readBytes(_ count: Int) async throws -> [UInt8] {
        while buffer.count - readIndex < count {
            try await fill()
        }
        let bytes = Array(buffer[readIndex..<readIndex + count])
        readIndex += count
        compact()
        return bytes
    }

    public func close() async {
        try? await channel.close().get()
    }

    private func fill() async throws {
        switch await iterator.next() {
        case .data(var bytes)?:
            buffer.append(contentsOf: bytes.readBytes(length: bytes.readableBytes) ?? [])
        case .failed(let error)?:
            throw error
        case .closed?, nil:
            throw ConnectionError.closed
        }
    }

    private func compact() {
        if readIndex > 64 * 1024 || readIndex == buffer.count {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}
