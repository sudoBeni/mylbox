import MylboxCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings().tabItem { Label("Accounts", systemImage: "at") }
            SpacesSettings().tabItem { Label("Spaces", systemImage: "square.stack") }
            RulesSettings().tabItem { Label("Rules", systemImage: "wand.and.stars") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 460)
    }
}

// MARK: - Accounts

struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Account?
    @State private var choosingProvider = false

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(model.config.accounts) { account in
                    HStack {
                        Avatar(name: account.name.isEmpty ? account.email : account.name)
                        VStack(alignment: .leading) {
                            Text(account.email).font(.headline)
                            Text(account.provider.displayName).font(.caption).foregroundStyle(.secondary)
                            if let error = model.accountErrors[account.id] {
                                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Edit…") { editing = account }
                        Button(role: .destructive) { model.removeAccount(account) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove account and its local mail")
                    }
                    .padding(.vertical, 4)
                }
            }
            .overlay {
                if model.config.accounts.isEmpty {
                    ContentUnavailableView("No accounts", systemImage: "at", description: Text("Add your first mail account."))
                }
            }
            HStack {
                Menu("Add Account") {
                    ForEach(Provider.allCases) { provider in
                        Button(provider.displayName) {
                            editing = Account(provider: provider, name: NSFullUserName(), email: "")
                        }
                    }
                }
                .fixedSize()
                Spacer()
            }
        }
        .padding()
        .sheet(item: $editing) { account in
            AccountEditor(account: account, isNew: model.account(account.id) == nil)
        }
    }
}

struct AccountEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    let isNew: Bool
    @State private var password = ""
    @State private var status: String?
    @State private var busy = false
    @State private var deviceCode: MicrosoftOAuth.DeviceCode?
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Your name", text: $account.name)
                    TextField("Email address", text: $account.email)
                        .onChange(of: account.email) { old, new in
                            if account.username.isEmpty || account.username == old { account.username = new }
                        }
                    if account.auth == .password {
                        SecureField("Password", text: $password, prompt: Text(isNew ? "App password" : "unchanged"))
                    }
                } footer: {
                    Text(account.provider.passwordHint).font(.caption).foregroundStyle(.secondary)
                }
                if account.auth == .microsoftOAuth {
                    Section("Microsoft sign-in") {
                        TextField("Azure app client ID", text: Binding(
                            get: { account.oauthClientID ?? "" },
                            set: { account.oauthClientID = $0.trimmingCharacters(in: .whitespaces) }))
                        if let deviceCode {
                            HStack {
                                Text("Enter code").foregroundStyle(.secondary)
                                Text(deviceCode.userCode).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                                Spacer()
                                Button("Open Sign-in Page") { NSWorkspace.shared.open(deviceCode.verificationURL) }
                            }
                        }
                        Button(hasRefreshToken ? "Sign In Again" : "Sign In with Microsoft") { signInMicrosoft() }
                            .disabled((account.oauthClientID ?? "").isEmpty || account.email.isEmpty || busy)
                    }
                }
                Section {
                    DisclosureGroup("Server settings", isExpanded: $showAdvanced) {
                        TextField("Username", text: $account.username)
                        endpointFields("IMAP (incoming)", $account.imap)
                        endpointFields("SMTP (outgoing)", $account.smtp)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Account" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || busy)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
        .onAppear { showAdvanced = account.provider == .imap }
    }

    private var hasRefreshToken: Bool { Keychain.get(Keychain.refreshTokenKey(account.id)) != nil }

    private var isValid: Bool {
        guard account.email.contains("@"), !account.imap.host.isEmpty, !account.smtp.host.isEmpty else { return false }
        switch account.auth {
        case .password: return !isNew || !password.isEmpty
        case .microsoftOAuth: return hasRefreshToken || deviceCode != nil
        }
    }

    private func endpointFields(_ title: String, _ endpoint: Binding<ServerEndpoint>) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("Host", text: endpoint.host).labelsHidden()
                TextField("Port", value: endpoint.port, format: .number.grouping(.never)).labelsHidden().frame(width: 60)
                Picker("", selection: endpoint.security) {
                    Text("SSL/TLS").tag(ConnectionSecurity.tls)
                    Text("STARTTLS").tag(ConnectionSecurity.startTLS)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func signInMicrosoft() {
        guard let clientID = account.oauthClientID else { return }
        busy = true
        status = "Waiting for sign-in in the browser…"
        let accountID = account.id
        Task {
            do {
                let code = try await MicrosoftOAuth.startDeviceFlow(clientID: clientID)
                deviceCode = code
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURL)
                let tokens = try await MicrosoftOAuth.waitForTokens(clientID: clientID, code: code)
                await Credentials.shared.store(tokens, for: accountID)
                deviceCode = nil
                status = "Signed in."
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }

    private func save() {
        busy = true
        status = "Checking connection…"
        let account = account
        let password = password
        Task {
            do {
                if account.auth == .password, !password.isEmpty {
                    try Keychain.set(password, for: Keychain.passwordKey(account.id))
                }
                let client = try await SyncEngine.session(for: account)
                await client.logout()
                model.updateConfig { config in
                    if let index = config.accounts.firstIndex(where: { $0.id == account.id }) {
                        config.accounts[index] = account
                    } else {
                        config.accounts.append(account)
                    }
                }
                dismiss()
                Task { await model.syncAll() }
            } catch {
                status = "Could not connect: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

// MARK: - Spaces

struct SpacesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Space?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Spaces collect mails about one topic. Each space can be mirrored as Markdown into another project, so that project (and its AI assistant) sees the mails.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach(model.config.spaces) { space in
                    HStack {
                        Image(systemName: space.symbol).frame(width: 24)
                        VStack(alignment: .leading) {
                            Text(space.name).font(.headline)
                            Text(space.exportFolder.map { "Exports to \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "Not exported")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editing = space }
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Button("New Space") { editing = Space(name: "") }
                Spacer()
                Button("Export All Now") { model.exportAll() }
            }
        }
        .padding()
        .sheet(item: $editing) { SpaceEditor(space: $0) }
    }
}

struct SpaceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var space: Space
    @State private var senders = ""
    @State private var error: String?

    static let symbols = ["folder", "volleyball", "banknote", "briefcase", "house", "graduationcap", "heart",
                          "person.2", "building.2", "cart", "airplane", "star"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $space.name, prompt: Text("e.g. Volleyball Finance"))
                    Picker("Icon", selection: $space.symbol) {
                        ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                    }
                    .pickerStyle(.palette)
                }
                Section {
                    TextField("Add mails automatically from", text: $senders,
                              prompt: Text("kasse@vbc.ch, @swissvolley.ch"), axis: .vertical)
                } footer: {
                    Text("Addresses or domains, separated by commas. New and existing mails from them join this space. For more control use Rules.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(space.exportFolder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                                .foregroundStyle(space.exportFolder == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { chooseFolder() }
                            if space.exportFolder != nil {
                                Button { space.exportFolder = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    Toggle("Include attachments", isOn: $space.includeAttachments)
                    Toggle("Keep mails out of git (adds a .gitignore)", isOn: $space.keepOutOfGit)
                } header: {
                    Text("Export to a project")
                } footer: {
                    Text("Pick a project, for example your volleyball finance repository. mylbox writes the mails into a \"mail\" folder inside it and keeps it up to date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.callout).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(space.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 540)
        .onAppear {
            // The space's sender rule shares the space's id.
            if let rule = model.config.rules.first(where: { $0.id == space.id }) {
                senders = rule.conditions.map(\.value).joined(separator: ", ")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the project (repository) that should see these mails."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let manifest = url.appendingPathComponent(".mylbox-export.json")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { $0 != ".DS_Store" } ?? []
        // Use a "mail" subfolder unless the chosen folder is empty or already a mylbox export.
        if FileManager.default.fileExists(atPath: manifest.path) || contents.isEmpty {
            space.exportFolder = url.path
        } else {
            space.exportFolder = url.appendingPathComponent("mail", isDirectory: true).path
        }
    }

    private func save() {
        space.name = space.name.trimmingCharacters(in: .whitespaces)
        let values = senders.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let space = space
        model.updateConfig { config in
            if let index = config.spaces.firstIndex(where: { $0.id == space.id }) {
                config.spaces[index] = space
            } else {
                config.spaces.append(space)
            }
            config.rules.removeAll { $0.id == space.id }
            if !values.isEmpty {
                var rule = Rule(name: "Mails for \(space.name)",
                                conditions: values.map { RuleCondition(field: .from, op: .contains, value: $0) },
                                actions: [.addToSpace(space.id)])
                rule.id = space.id
                rule.matchAll = false
                config.rules.append(rule)
            }
        }
        Task { await model.applyRules(everything: true) }
        if model.exportAll().isEmpty || space.exportFolder == nil {
            dismiss()
        } else {
            error = model.banner
            model.banner = nil
        }
    }
}

// MARK: - Rules

struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Rules run on every new mail. They can sort mail into spaces, set a category, archive, mark read or flag.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach(model.config.rules) { rule in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { value in model.updateConfig { config in
                                if let index = config.rules.firstIndex(where: { $0.id == rule.id }) { config.rules[index].enabled = value }
                            } }))
                            .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(rule.name).font(.headline)
                            Text(RuleText.describe(rule, spaces: model.config.spaces))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Edit…") { editing = rule }
                        Button(role: .destructive) {
                            model.updateConfig { $0.rules.removeAll { $0.id == rule.id } }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { from, to in model.updateConfig { $0.rules.move(fromOffsets: from, toOffset: to) } }
            }
            HStack {
                Button("New Rule") { editing = Rule(name: "") }
                Spacer()
                Button("Apply Rules to All Mail") { Task { await model.applyRules(everything: true) } }
            }
        }
        .padding()
        .sheet(item: $editing) { RuleEditor(rule: $0) }
    }
}

enum RuleText {
    static func describe(_ rule: Rule, spaces: [Space]) -> String {
        let conditions = rule.conditions.map { "\($0.field.displayName) \($0.op.displayName) “\($0.value)”" }
            .joined(separator: rule.matchAll ? " and " : " or ")
        let actions = rule.actions.map { action -> String in
            switch action {
            case .addToSpace(let id): "add to \(spaces.first { $0.id == id }?.name ?? "space")"
            case .setCategory(let category): "move to \(category.displayName)"
            case .archive: "archive"
            case .markRead: "mark read"
            case .flag: "flag"
            }
        }.joined(separator: ", ")
        return "If \(conditions) → \(actions.isEmpty ? "do nothing" : actions)"
    }
}

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    @State private var spaceIDs: Set<UUID> = []
    @State private var category: MailCategory?
    @State private var archive = false
    @State private var markRead = false
    @State private var flag = false
    @State private var applyToExisting = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $rule.name, prompt: Text("e.g. Volleyball invoices"))
                    Picker("Match", selection: $rule.matchAll) {
                        Text("all conditions").tag(true)
                        Text("any condition").tag(false)
                    }
                }
                Section("If") {
                    ForEach($rule.conditions) { $condition in
                        HStack {
                            Picker("", selection: $condition.field) {
                                ForEach(RuleField.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            Picker("", selection: $condition.op) {
                                ForEach(RuleOperator.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            TextField("", text: $condition.value).labelsHidden()
                            Button {
                                rule.conditions.removeAll { $0.id == condition.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(rule.conditions.count == 1)
                        }
                    }
                    Button("Add Condition") { rule.conditions.append(RuleCondition()) }
                }
                Section("Then") {
                    ForEach(model.config.spaces) { space in
                        Toggle("Add to \(space.name)", isOn: Binding(
                            get: { spaceIDs.contains(space.id) },
                            set: { if $0 { spaceIDs.insert(space.id) } else { spaceIDs.remove(space.id) } }))
                    }
                    Picker("Category", selection: $category) {
                        Text("Don't change").tag(MailCategory?.none)
                        ForEach(MailCategory.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Toggle("Mark as read", isOn: $markRead)
                    Toggle("Flag", isOn: $flag)
                    Toggle("Archive", isOn: $archive)
                }
                Section {
                    Toggle("Also apply to existing mail", isOn: $applyToExisting)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.conditions.allSatisfy { $0.value.trimmingCharacters(in: .whitespaces).isEmpty })
            }
            .padding()
        }
        .frame(width: 600, height: 560)
        .onAppear(perform: load)
    }

    private func load() {
        for action in rule.actions {
            switch action {
            case .addToSpace(let id): spaceIDs.insert(id)
            case .setCategory(let value): category = value
            case .archive: archive = true
            case .markRead: markRead = true
            case .flag: flag = true
            }
        }
    }

    private func save() {
        var actions: [RuleAction] = spaceIDs.sorted { $0.uuidString < $1.uuidString }.map { .addToSpace($0) }
        if let category { actions.append(.setCategory(category)) }
        if markRead { actions.append(.markRead) }
        if flag { actions.append(.flag) }
        if archive { actions.append(.archive) }
        rule.actions = actions
        rule.conditions.removeAll { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            rule.name = rule.conditions.first.map { "\($0.field.displayName): \($0.value)" } ?? "Rule"
        }
        let rule = rule
        model.updateConfig { config in
            if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
                config.rules[index] = rule
            } else {
                config.rules.append(rule)
            }
        }
        if applyToExisting { Task { await model.applyRules(everything: true) } }
        dismiss()
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Sort mail with local AI", isOn: Binding(
                    get: { model.config.aiClassificationEnabled },
                    set: { value in model.updateConfig { $0.aiClassificationEnabled = value } }))
                Picker("Model", selection: Binding(
                    get: { model.config.aiModelID },
                    set: { value in model.updateConfig { $0.aiModelID = value } })) {
                    ForEach(LocalModelCatalog.models) { info in
                        Text(info.name).tag(info.id)
                    }
                }
                .disabled(model.modelDownloadProgress != nil)
                LabeledContent("Status") {
                    let info = model.selectedModel
                    if let progress = model.modelDownloadProgress {
                        HStack {
                            ProgressView(value: progress).frame(width: 140)
                            Text("\(Int(progress * 100)) %").monospacedDigit()
                            Button("Cancel") { model.cancelModelDownload() }
                        }
                    } else if info.isDownloaded {
                        HStack {
                            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Delete") { model.deleteModel(info) }
                        }
                    } else {
                        Button("Download (\(ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)))") {
                            model.downloadModel()
                        }
                    }
                }
                Text(model.selectedModel.detail).font(.caption).foregroundStyle(.secondary)
                Button("Re-sort Inbox with AI") { Task { await model.retriageAll() } }
                    .disabled(!model.selectedModel.isDownloaded || !model.config.aiClassificationEnabled)
            } header: {
                Text("AI")
            } footer: {
                Text("An open-source language model runs directly on this Mac. It sorts mail into Important, Updates, Newsletters and Spam, marks mails that need a reply and writes one-line summaries. Your mail never leaves the Mac. Rules and your own choices always win.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sync") {
                Picker("Check for mail every", selection: Binding(
                    get: { model.config.syncIntervalMinutes },
                    set: { value in model.updateConfig { $0.syncIntervalMinutes = value } })) {
                    ForEach([1, 3, 5, 10, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("First download per account", selection: Binding(
                    get: { model.config.initialSyncLimit },
                    set: { value in model.updateConfig { $0.initialSyncLimit = value } })) {
                    ForEach([100, 300, 1000, 5000], id: \.self) { Text("\($0) newest mails").tag($0) }
                }
                LabeledContent("Local data") {
                    Button("Show in Finder") { NSWorkspace.shared.open(Paths.appSupport) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
