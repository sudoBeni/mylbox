import Foundation

/// A language model that answers a system and a user prompt with text (JSON for RallyMail's prompts): the local
/// model on the Mac, or a cloud model through OpenRouter.
public protocol TextModel: Sendable {
    func complete(system: String, user: String, grammar: String?, maxTokens: Int) async throws -> String
}

extension LocalModel: TextModel {}

/// A model on OpenRouter, used only where the user switched it on (setting RallyMail up). It gets what a prompt
/// contains and nothing else; the key lives in the Keychain.
public struct OpenRouter: TextModel {
    public static let keychainKey = "openrouter.apiKey"
    static let base = URL(string: "https://openrouter.ai/api/v1/")!

    public let apiKey: String
    public let model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// One answer. The grammar is for the local model; a cloud model is asked for JSON in the prompt instead, and
    /// whatever it writes around the JSON object is cut off.
    public func complete(system: String, user: String, grammar: String? = nil, maxTokens: Int = 200) async throws -> String {
        var request = URLRequest(url: Self.base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RallyMail", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "max_tokens": max(maxTokens, 400),
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let error = object?["error"] as? [String: Any] {
            throw Failure(message: "OpenRouter: \(error["message"] as? String ?? "error")")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let choices = object?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw Failure(message: "OpenRouter answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return Self.jsonObject(in: content)
    }

    /// The JSON object in a model's answer, without code fences or words around it.
    static func jsonObject(in text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }

    /// A model OpenRouter offers.
    public struct Model: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var created: Date
        /// Dollars per million input tokens.
        public var pricePerMillion: Double
    }

    /// The text models OpenRouter offers, newest first (no key needed).
    public static func models() async throws -> [Model] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("models"))
        let list = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let output = ((item["architecture"] as? [String: Any])?["output_modalities"] as? [String]) ?? ["text"]
            guard output.contains("text") else { return nil }
            let price = Double(((item["pricing"] as? [String: Any])?["prompt"] as? String) ?? "") ?? 0
            return Model(id: id, name: item["name"] as? String ?? id,
                         created: Date(timeIntervalSince1970: item["created"] as? Double ?? 0), pricePerMillion: price * 1_000_000)
        }
        .sorted { $0.created > $1.created }
    }

    /// The default: the newest Claude Sonnet, else the newest model.
    public static func preferred(in models: [Model]) -> Model? {
        models.first { $0.id.hasPrefix("anthropic/claude-sonnet") && !$0.id.contains(":") } ?? models.first
    }
}
