import RallyMailCore
import SwiftUI

/// The bar across the top: the three places (Play, Inbox, Courts), search, and a new mail.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let mine = model.matters.filter { $0.ball == .mine && !$0.isFolded }.count
        let courts = model.config.spaces.filter { $0.id != model.config.graveyardID }.count
        HStack(spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Palette.me, in: RoundedRectangle(cornerRadius: 8))
                Text("RallyMail").font(.system(size: 14.5, weight: .bold))
            }
            HStack(spacing: 3) {
                tab("Play", count: mine, hot: true, on: isPlay) { model.screen = .play }
                tab("Inbox", count: model.fresh.count, hot: false, on: model.screen == .inbox) { model.screen = .inbox }
                tab("Courts", count: courts, hot: nil, on: isCourts) { model.screen = .courts(nil) }
            }
            .padding(3)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 11))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("Mails, topics, people, attachments …", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { model.search(query) }
                if query.isEmpty {
                    Text("⌘K").font(.system(size: 10.5)).foregroundStyle(Palette.faint)
                        .padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0xD6D2CB)))
                } else {
                    Button { query = ""; model.search("") } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 520)
            .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
            .onChange(of: model.feedQuery.search) { _, text in if text != query { query = text } }
            // The window must not start typing into the search: it takes focus only on click or ⌘K.
            .onAppear { Task { searchFocused = false } }
            Spacer(minLength: 0)
            SyncStatusView()
            Button { model.newMail() } label: {
                Label("New Mail", systemImage: "plus").font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help("New mail (⌘N)")
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
        .background(Palette.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var isPlay: Bool {
        if model.screen == .play { return true }
        if case .topic = model.screen { return true }
        return false
    }

    private var isCourts: Bool {
        if case .courts = model.screen { return true }
        return model.screen == .sorting
    }

    /// One place in the bar. `hot`: orange count (Play), dark count (Inbox), plain count (nil).
    private func tab(_ title: String, count: Int, hot: Bool?, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            model.newDraft = nil
            action()
        } label: {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 13, weight: on ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hot == nil ? Palette.muted : .white)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(hot == nil ? Color.clear : hot == true ? Palette.me : Palette.ink, in: Capsule())
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(on ? Palette.panel : .clear, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: on ? .black.opacity(0.1) : .clear, radius: 1, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
