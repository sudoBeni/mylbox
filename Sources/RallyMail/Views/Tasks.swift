import RallyMailCore
import SwiftUI

/// An open task in a topic: tick it off when it is done, or dismiss what the model got wrong. When a mail the
/// user sent sounds like it is done, the row asks instead of deciding.
struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: MailTask
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { model.completeTask(task) } label: {
                    Image(systemName: hovered ? "checkmark.square" : "square")
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("Done")
                Text(task.label).font(.system(size: 12.5))
                Spacer(minLength: 4)
                if task.source == .model {
                    Button { model.dismissTask(task) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Not a task")
                }
            }
            if task.doneSuggestedBy != nil {
                HStack(spacing: 6) {
                    Text("Your mail sounds like it's done.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Done") { model.completeTask(task) }.controlSize(.small)
                    Button("Not yet") { model.rejectDoneSuggestion(task) }.buttonStyle(.link).font(.system(size: 11))
                }
                .padding(.leading, 20)
            }
        }
    }
}

/// Above the send button: open tasks of the topic, to tick off together with the reply. Off by default, since
/// answering is not doing.
struct ComposerTaskToggles: View {
    let tasks: [MailTask]
    @Binding var finishing: Set<Int64>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tasks) { task in
                Toggle(isOn: Binding(get: { finishing.contains(task.id) },
                                     set: { if $0 { finishing.insert(task.id) } else { finishing.remove(task.id) } })) {
                    Text("Done: \(task.label)").lineLimit(1)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .help("Ticks the task off when this mail is sent")
            }
        }
    }
}
