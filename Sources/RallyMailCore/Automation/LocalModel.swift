import Foundation
import llama

public struct LocalModelError: LocalizedError {
    public let message: String
    public var errorDescription: String? { "Local model: \(message)" }
}

/// A GGUF language model running on this Mac through llama.cpp (Metal accelerated).
/// All llama calls run on one serial queue; the class is safe to use from any task.
public final class LocalModel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ch.rallymail.llama")
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let template: String?
    public let contextSize: Int

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// Loads a model file. This takes a few seconds and a few GB of memory, so keep the instance around.
    public init(path: String, contextSize: Int = 4096) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LocalModelError(message: "cannot load \((path as NSString).lastPathComponent)")
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(contextSize)
        contextParams.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        contextParams.n_threads_batch = contextParams.n_threads
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw LocalModelError(message: "the model has no vocabulary")
        }
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LocalModelError(message: "cannot create a context")
        }
        self.model = model
        self.context = context
        self.vocab = vocab
        self.template = llama_model_chat_template(model, nil).map { String(cString: $0) }
        self.contextSize = contextSize
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Runs one chat turn and returns the answer. `grammar` (GBNF) constrains the output, e.g. to JSON.
    public func complete(system: String, user: String, grammar: String? = nil, maxTokens: Int = 200) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.run(system: system, user: user, grammar: grammar, maxTokens: maxTokens)
                })
            }
        }
    }

    private func run(system: String, user: String, grammar: String?, maxTokens: Int) throws -> String {
        let prompt = try format(system: system, user: user)
        var tokens = tokenize(prompt)
        guard tokens.count + maxTokens < contextSize else { throw LocalModelError(message: "the mail is too long") }

        llama_memory_clear(llama_get_memory(context), true)
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if let grammar {
            guard let constraint = llama_sampler_init_grammar(vocab, grammar, "root") else {
                throw LocalModelError(message: "invalid grammar")
            }
            llama_sampler_chain_add(sampler, constraint)
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw LocalModelError(message: "decoding failed (\(status))") }

        var output: [UInt8] = []
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token)
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw LocalModelError(message: "decoding failed (\(status))") }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func format(system: String, user: String) throws -> String {
        let roles = [("system", system), ("user", user)]
        // The C strings must stay alive while the template is applied.
        let cStrings = roles.map { (strdup($0.0)!, strdup($0.1)!) }
        defer { cStrings.forEach { free($0.0); free($0.1) } }
        var messages = cStrings.map { llama_chat_message(role: $0.0, content: $0.1) }
        var buffer = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 512)
        var length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
        if length > buffer.count {
            buffer = [CChar](repeating: 0, count: Int(length) + 1)
            length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
        }
        if length > 0 {
            return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        // Formats llama.cpp's built-in template list doesn't know yet (BOS is added when tokenizing).
        if let fallback = Self.fallbackFormat(template: template, system: system, user: user) { return fallback }
        throw LocalModelError(message: "the model has no usable chat template")
    }

    static func fallbackFormat(template: String?, system: String, user: String) -> String? {
        guard let template else { return nil }
        if template.contains("<|turn>") { // Gemma 4
            return "<|turn>system\n\(system)<turn|>\n<|turn>user\n\(user)<turn|>\n<|turn>model\n"
        }
        if template.contains("<|im_start|>") { // ChatML (Qwen and others)
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        return nil
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, count))).map { UInt8(bitPattern: $0) }
    }
}
