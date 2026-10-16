import Foundation

/// Reads a deadline out of a task or a request ("bis Freitag", "bis 23.10.", "payable within 30 days"), by rules
/// only. Dates are read relative to when the mail came. Nothing is guessed: no date words, no deadline.
public enum DueDate {
    /// The earliest date the text names, as the start of that day; nil when it names none.
    public static func find(in text: String, from reference: Date, calendar: Calendar = .current) -> Date? {
        let lower = text.lowercased()
        let start = calendar.startOfDay(for: reference)
        var found: [Date] = []
        func add(_ days: Int) { if let date = calendar.date(byAdding: .day, value: days, to: start) { found.append(date) } }

        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wordSet = Set(words)
        if wordSet.contains("heute") || wordSet.contains("today") || lower.contains("sofort") { add(0) }
        if wordSet.contains("übermorgen") { add(2) } else if wordSet.contains("morgen") || wordSet.contains("tomorrow") { add(1) }
        if lower.contains("ende monat") || lower.contains("ende des monats") || lower.contains("end of the month") || lower.contains("end of month"),
           let range = calendar.range(of: .day, in: .month, for: start) {
            let day = calendar.component(.day, from: start)
            add(range.count - day)
        }
        if lower.contains("nächste woche") || lower.contains("next week") { add(7) }

        // Weekdays: the next one, today included.
        let today = calendar.component(.weekday, from: start)
        for (index, word) in words.enumerated() {
            guard let weekday = weekdays[word] else { continue }
            // "Montag, 3. November" is a date, read below; a weekday right before a number is its name only.
            if index + 1 < words.count, Int(words[index + 1]) != nil { continue }
            add((weekday - today + 7) % 7)
        }

        // "in 30 Tagen", "innert 10 Tagen", "within 30 days".
        for (index, word) in words.enumerated() where ["in", "innert", "innerhalb", "within"].contains(word) {
            var next = index + 1
            if next < words.count, words[next] == "von" { next += 1 }
            guard next + 1 < words.count, let count = Int(words[next]), count > 0, count <= 120 else { continue }
            let unit = words[next + 1]
            if unit.hasPrefix("tag") || unit.hasPrefix("day") { add(count) }
            if unit.hasPrefix("woche") || unit.hasPrefix("week") { add(count * 7) }
        }

        // 23.10. / 23.10.2026 / 23.10.26
        for match in numericDates.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let day = int(match, 1, lower), let month = int(match, 2, lower) else { continue }
            var year = int(match, 3, lower)
            if let short = year, short < 100 { year = 2000 + short }
            if let date = make(day: day, month: month, year: year, after: start, calendar: calendar) { found.append(date) }
        }
        // 31. Oktober / 3 Nov / October 31
        for match in namedDates.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let day = int(match, 1, lower), let name = string(match, 2, lower), let month = months[name] else { continue }
            if let date = make(day: day, month: month, year: int(match, 3, lower), after: start, calendar: calendar) { found.append(date) }
        }
        for match in namedDatesEnglish.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            guard let name = string(match, 1, lower), let month = months[name], let day = int(match, 2, lower) else { continue }
            if let date = make(day: day, month: month, year: int(match, 3, lower), after: start, calendar: calendar) { found.append(date) }
        }
        return found.min()
    }

    private static func make(day: Int, month: Int, year: Int?, after start: Date, calendar: Calendar) -> Date? {
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        let referenceYear = calendar.component(.year, from: start)
        var components = DateComponents(year: year ?? referenceYear, month: month, day: day)
        guard var date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        // Without a year, a date more than a month back means next year ("bis 10.1." written in December).
        if year == nil, date < calendar.date(byAdding: .day, value: -31, to: start) ?? start {
            components.year = referenceYear + 1
            date = calendar.date(from: components) ?? date
        }
        return date
    }

    private static func int(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> Int? {
        string(match, group, text).flatMap { Int($0) }
    }

    private static func string(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> String? {
        guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static let numericDates = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(?:(\d{4}|\d{2})(?!\d))?"#)
    private static let namedDates = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\.?\s+([a-zäéû]+)\.?(?:\s+(\d{4}))?"#)
    private static let namedDatesEnglish = try! NSRegularExpression(pattern: #"\b([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4}))?"#)

    private static let weekdays: [String: Int] = [
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static let months: [String: Int] = [
        "januar": 1, "jan": 1, "january": 1, "februar": 2, "feb": 2, "february": 2, "märz": 3, "mär": 3, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "mai": 5, "may": 5, "juni": 6, "jun": 6, "june": 6, "juli": 7, "jul": 7, "july": 7,
        "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9, "oktober": 10, "okt": 10, "october": 10, "oct": 10,
        "november": 11, "nov": 11, "dezember": 12, "dez": 12, "december": 12, "dec": 12,
    ]
}
