import Foundation
import Testing
@testable import RallyMailCore

@Suite struct DueDateTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }()

    /// Friday, 16 October 2026, 09:00.
    var friday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))! }

    func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func due(_ text: String) -> Date? { DueDate.find(in: text, from: friday, calendar: calendar) }

    @Test func relativeWords() {
        #expect(due("Vollmacht heute noch schicken") == day(10, 16))
        #expect(due("Lea bis morgen Bescheid geben") == day(10, 17))
        #expect(due("Reply by tomorrow") == day(10, 17))
        #expect(due("Beleg bis Ende Monat einreichen") == day(10, 31))
        #expect(due("Schlussrechnung zahlen, payable within 30 days") == day(11, 15))
        #expect(due("Rechnung innert 10 Tagen bezahlen") == day(10, 26))
    }

    @Test func weekdays() {
        #expect(due("Anmeldeformular bis Freitag schicken") == day(10, 16))
        #expect(due("Offerte bis Dienstag") == day(10, 20))
        #expect(due("Send it by Monday") == day(10, 19))
        // A weekday before a date names the date.
        #expect(due("Treffen Montag, 3. November") == day(11, 3))
    }

    @Test func dates() {
        #expect(due("Rechnung CHF 49 bezahlen bis 23.10.") == day(10, 23))
        #expect(due("bis 5.1.2027 unterschreiben") == day(1, 5, 2027))
        #expect(due("Beleg bis 31. Oktober einreichen") == day(10, 31))
        #expect(due("Kündigung bis 30. Nov. schicken") == day(11, 30))
        #expect(due("Due October 31st") == day(10, 31))
        // Without a year, a date long past is next year's.
        #expect(due("Prämie bis 10.1. bezahlen") == day(1, 10, 2027))
        // The earliest one counts.
        #expect(due("bis 30.10., spätestens 5.11.") == day(10, 30))
    }

    @Test func nothingToFind() {
        #expect(due("Hallenmiete bestätigen") == nil)
        #expect(due("Rechnung CHF 1’500 an Garage Meier schicken") == nil)
        #expect(due("Version 2.3 testen") == nil)
        #expect(due("in 3 Minuten") == nil)
    }
}
