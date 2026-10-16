import AVFoundation
import Foundation
import Observation
import RallyMailCore

/// A question to Rally and what it found.
struct RallyEntry: Identifiable {
    enum Answer {
        case topics([String])
        case mails([Int64])
        case text(String)
    }

    let id = UUID()
    var question: String
    var intro: String
    var answer: Answer
}

/// The questions Rally answers with one click.
enum RallyPrompt: CaseIterable {
    case yourTurn, waiting, unsorted

    var question: String {
        switch self {
        case .yourTurn: "Where is the ball with me?"
        case .waiting: "What am I waiting for?"
        case .unsorted: "What has no court yet?"
        }
    }
}

extension AppModel {
    func ask(_ prompt: RallyPrompt) {
        rallyLog.append(answer(prompt))
    }

    private func answer(_ prompt: RallyPrompt) -> RallyEntry {
        switch prompt {
        case .yourTurn:
            let list = matters.filter { $0.ball == .mine && !$0.isFolded }
            return RallyEntry(question: prompt.question, intro: list.isEmpty ? "Nowhere. You're through." : "In \(list.count) topic\(list.count == 1 ? "" : "s"):",
                              answer: .topics(list.map(\.id)))
        case .waiting:
            let list = matters.filter { $0.ball == .theirs }
            return RallyEntry(question: prompt.question, intro: list.isEmpty ? "Nobody." : "You wait for:", answer: .topics(list.map(\.id)))
        case .unsorted:
            let list = fresh.filter { matter(of: $0)?.spaceID == nil }
            return RallyEntry(question: prompt.question, intro: list.isEmpty ? "All new mail has its court." : "New mail without a court:",
                              answer: .mails(list.map(\.id)))
        }
    }

    /// A question in the user's words. Answered from the mail itself: the prompts, a topic by name, or a search.
    func ask(question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let lower = text.lowercased()
        if lower.contains("ball") || lower.contains("dran") || lower.contains("my turn") {
            var entry = answer(.yourTurn); entry.question = text; rallyLog.append(entry); return
        }
        if lower.contains("wait") || lower.contains("wart") {
            var entry = answer(.waiting); entry.question = text; rallyLog.append(entry); return
        }
        if lower.contains("court") || lower.contains("zugeordnet") || lower.contains("unsorted") {
            var entry = answer(.unsorted); entry.question = text; rallyLog.append(entry); return
        }
        let filler: Set<String> = ["wo", "ist", "sind", "die", "der", "das", "den", "mail", "mails", "von", "mit", "was", "zeig", "mir",
                                   "where", "is", "the", "what", "about", "show", "me", "find", "a", "an", "of", "from", "with"]
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !filler.contains($0) }
        if !lower.hasPrefix("wo"), !lower.hasPrefix("where"),
           let topic = matters.first(where: { matter in words.contains { matter.title.lowercased().contains($0) } && !matter.isFolded }) {
            rallyLog.append(RallyEntry(question: text, intro: "This topic:", answer: .topics([topic.id])))
            return
        }
        var query = FeedQuery()
        query.search = words.joined(separator: " ")
        query.limit = 5
        let found = words.isEmpty ? [] : ((try? store.feed(query)) ?? [])
        if found.isEmpty {
            rallyLog.append(RallyEntry(question: text, intro: "", answer: .text("I found nothing for that. Try a name, a word from the mail or a file name.")))
        } else {
            rallyLog.append(RallyEntry(question: text, intro: "I found:", answer: .mails(found.map(\.id))))
        }
    }

    /// The new mail, read out: who wrote, in which topic, and what it is about.
    var spokenBriefing: String {
        let german = Locale.current.language.languageCode?.identifier == "de"
        guard !fresh.isEmpty else { return german ? "Keine neuen Mails." : "No new mail." }
        var parts = [german ? "\(fresh.count) neue Mails." : "\(fresh.count) new mails."]
        for message in fresh.prefix(20) {
            let topic = matter(of: message).map { $0.title } ?? ""
            let what = message.summary ?? Threading.normalizedSubject(message.subject)
            let from = message.from.displayName
            parts.append(german ? "\(from)\(topic.isEmpty ? "" : ", zu \(topic)"): \(what)." : "\(from)\(topic.isEmpty ? "" : ", about \(topic)"): \(what).")
        }
        return parts.joined(separator: " ")
    }
}

/// Reads text aloud with the system's voice; nothing leaves the Mac.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier == "de" ? "de-CH" : nil)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
