import RallyMailCore
import SwiftUI

/// Every received mail, new on top, searchable. The mail comes first; on the right of each row where it belongs
/// (or RallyMail's suggestion). Infos of a day are bundled in one row.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var months: [(month: Date, count: Int)] = []
    @State private var openInfos: Set<String> = []
    @AppStorage("inboxHideInfos") private var hideInfos = false

    private var filtered: Bool {
        let query = model.feedQuery
        return !query.search.isEmpty || query.space != nil || query.attachmentsOnly || query.from != nil
            || query.unreadOnly || query.before != nil || model.inboxOnlyUnplaced
    }

    var body: some View {
        @Bindable var model = model
        let newIDs = Set(model.fresh.map(\.id))
        let showNew = !filtered && !model.fresh.isEmpty
        let shown = visible(showNew ? model.feed.filter { !newIDs.contains($0.id) } : model.feed)
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: .sectionHeaders) {
                    if showNew {
                        let fresh = visible(model.fresh)
                        Section { rows(fresh, day: "new") } header: { dayHeader("New · \(fresh.count)", accent: true) }
                    }
                    ForEach(days(shown), id: \.label) { group in
                        Section { rows(group.items, day: group.label) } header: { dayHeader(group.label) }
                    }
                    if model.feed.isEmpty {
                        Text(filtered ? "Nothing found. Try a name, a word from the mail or a file name." : "No mail yet.")
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else if model.feed.count >= model.feedQuery.limit {
                        Button("Show More") { model.feedQuery.limit += 300 }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Palette.panel)
        .onAppear { months = (try? model.store.monthCounts()) ?? [] }
        .onDisappear { model.inboxOnlyUnplaced = false }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.return) {
            guard let selection = model.selection else { return .ignored }
            model.open(topic: selection.matterKey, at: selection.id)
            return .handled
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var model = model
        let total = months.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Inbox").font(.system(size: 20, weight: .bold))
                Text("\(total.formatted()) mails" + (months.last.map { " since \($0.month.formatted(.dateTime.month(.wide).year()))" } ?? "")
                     + " · new on top · nothing is deleted")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
                Spacer()
                if !model.fresh.isEmpty {
                    Button("All Seen") { model.markSeen(model.fresh) }
                        .buttonStyle(SmallButtonStyle(filled: false))
                        .help("Marks all new mail as seen")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("Search: name, subject, text, file", text: $model.feedQuery.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 9))
            FlowLayout(spacing: 6) {
                filter("All", on: !filtered) {
                    model.feedQuery = FeedQuery()
                    model.inboxOnlyUnplaced = false
                }
                filter("New only · \(model.fresh.count)", on: model.feedQuery.unreadOnly) { model.feedQuery.unreadOnly.toggle() }
                filter("No place · \(model.unplaced.count)", on: model.inboxOnlyUnplaced) { model.inboxOnlyUnplaced.toggle() }
                filter("With attachments", on: model.feedQuery.attachmentsOnly) { model.feedQuery.attachmentsOnly.toggle() }
                Menu {
                    Button("All Courts") { model.feedQuery.space = nil }
                    Divider()
                    ForEach(model.config.spaces) { court in Button(court.name) { model.feedQuery.space = court.id } }
                } label: {
                    Text(model.space(model.feedQuery.space).map { "Court: \($0.name)" } ?? "Court ▾")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(model.feedQuery.space == nil ? Palette.chip : Palette.ink.opacity(0.12), in: Capsule())
                filter(hideInfos ? "Infos hidden" : "Hide Infos", on: hideInfos) { hideInfos.toggle() }
                if let from = model.feedQuery.from {
                    filter("From \(from) ✕", on: true) { model.feedQuery.from = nil }
                }
            }
            if !months.isEmpty { jumpBar }
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xECE9E4)).frame(height: 1) }
    }

    private func filter(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Palette.ink)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(on ? Palette.ink : Palette.chip, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Jump through the years: the newest, the recent months one by one, older years as a whole.
    private var jumpBar: some View {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let recent = months.filter { calendar.component(.year, from: $0.month) >= year - 1 }.prefix(6)
        let older = Dictionary(grouping: months.filter { item in !recent.contains { $0.month == item.month } }) { calendar.component(.year, from: $0.month) }
            .map { (year: $0.key, count: $0.value.reduce(0) { $0 + $1.count }) }
            .sorted { $0.year > $1.year }
        return FlowLayout(spacing: 4) {
            Text("Jump to").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.trailing, 4).padding(.vertical, 2)
            jump("Newest", on: model.feedQuery.before == nil, hot: true) { model.feedQuery.before = nil }
            ForEach(Array(recent), id: \.month) { item in
                let end = calendar.date(byAdding: .month, value: 1, to: item.month)
                jump("\(item.month.formatted(.dateTime.month(.abbreviated))) \(item.count)", on: model.feedQuery.before == end, hot: false) {
                    model.feedQuery.before = end
                }
            }
            ForEach(older.prefix(4), id: \.year) { item in
                let end = calendar.date(from: DateComponents(year: item.year + 1, month: 1, day: 1))
                jump("\(String(item.year)) \(item.count)", on: model.feedQuery.before == end, hot: false) { model.feedQuery.before = end }
            }
            if older.count > 4, let last = older.dropFirst(4).first, let first = older.last {
                let end = calendar.date(from: DateComponents(year: last.year + 1, month: 1, day: 1))
                jump("\(String(first.year))–\(String(last.year)) \(older.dropFirst(4).reduce(0) { $0 + $1.count })",
                     on: model.feedQuery.before == end, hot: false) { model.feedQuery.before = end }
            }
        }
    }

    private func jump(_ title: String, on: Bool, hot: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color(hex: 0xA83A16) : Color(hex: 0x4D4A46))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(on ? Color(hex: 0xFDE6DC) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Rows

    /// The mails of one day: each on its own, the day's infos in one row that opens on click.
    @ViewBuilder private func rows(_ messages: [MailMessage], day: String) -> some View {
        let bundle = bundling
        let infos = bundle ? messages.filter(isInfo) : []
        let personal = bundle ? messages.filter { !isInfo($0) } : messages
        ForEach(personal) { MailRow(message: $0) }
        if !infos.isEmpty {
            if openInfos.contains(day) {
                ForEach(infos) { MailRow(message: $0) }
                Button("Fold the infos") { openInfos.remove(day) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.leading, 60).padding(.vertical, 4)
            } else {
                InfoBundleRow(messages: infos) { openInfos.insert(day) }
            }
        }
    }

    /// Infos are bundled unless the user looks for something or at the Infos court.
    private var bundling: Bool {
        model.feedQuery.search.isEmpty && model.feedQuery.space == nil && model.feedQuery.from == nil
    }

    private func isInfo(_ message: MailMessage) -> Bool {
        guard let infos = model.config.infosID else { return false }
        return model.matter(of: message)?.spaceID == infos
    }

    private func visible(_ messages: [MailMessage]) -> [MailMessage] {
        messages.filter { message in
            (!hideInfos || !isInfo(message)) && (!model.inboxOnlyUnplaced || model.matter(of: message)?.spaceID == nil)
        }
    }

    private func dayHeader(_ title: String, accent: Bool = false) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(accent ? Palette.meText : Palette.muted)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel)
    }

    /// One group per day: "Today", "Yesterday", "Wed, 14 Oct", with its count.
    private func days(_ messages: [MailMessage]) -> [(label: String, items: [MailMessage])] {
        let calendar = Calendar.current
        var groups: [(String, [MailMessage])] = []
        for message in messages {
            let label: String
            if calendar.isDateInToday(message.date) { label = "Today" }
            else if calendar.isDateInYesterday(message.date) { label = "Yesterday" }
            else if calendar.component(.year, from: message.date) == calendar.component(.year, from: Date()) {
                label = message.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            } else {
                label = message.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
            }
            if groups.last?.0 == label { groups[groups.count - 1].1.append(message) } else { groups.append((label, [message])) }
        }
        return groups.map { (label: "\($0.0) · \($0.1.count)", items: $0.1) }
    }

    /// Up and down walk the list; the reading pane follows.
    private func step(_ delta: Int) {
        let newIDs = Set(model.fresh.map(\.id))
        let order = visible(filtered || model.fresh.isEmpty ? model.feed : model.fresh + model.feed.filter { !newIDs.contains($0.id) })
        guard !order.isEmpty else { return }
        let current = model.selectedMessage.flatMap { id in order.firstIndex { $0.id == id } } ?? -1
        model.selectedMessage = order[min(max(current + delta, 0), order.count - 1)].id
    }
}

/// A day's infos in one row: how many, from whom; opens on click.
private struct InfoBundleRow: View {
    @Environment(AppModel.self) private var model
    let messages: [MailMessage]
    let open: () -> Void

    var body: some View {
        var counts: [(String, Int)] = []
        for message in messages {
            let name = message.from.displayName
            if let index = counts.firstIndex(where: { $0.0 == name }) { counts[index].1 += 1 } else { counts.append((name, 1)) }
        }
        let senders = counts.map { $0.1 > 1 ? "\($0.0) (\($0.1))" : $0.0 }.joined(separator: ", ")
        let unread = messages.contains { !$0.isRead }
        return Button(action: open) {
            HStack(spacing: 10) {
                Circle().fill(unread ? Palette.me : Color.clear).frame(width: 8, height: 8)
                Text("\(messages.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color(hex: 0x8A8580), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Infos · \(messages.count) mail\(messages.count == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
                    Text(senders).font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer()
                Text("open ›").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(hex: 0xF7F5F2), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
