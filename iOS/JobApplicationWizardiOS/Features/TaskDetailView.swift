import SwiftUI
import JobApplicationShared

struct TaskDetailView: View {
    let task: SubTask

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(task.isCompleted ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.title3)
                            .fontWeight(.medium)
                            .strikethrough(task.isCompleted)
                        Text(task.isCompleted ? "Completed" : "Pending")
                            .font(.subheadline)
                            .foregroundStyle(task.isCompleted ? .green : .orange)
                    }
                }
            }

            Section("Details") {
                LabeledContent("For Status") {
                    HStack(spacing: 4) {
                        Image(systemName: task.forStatus.icon)
                            .foregroundStyle(task.forStatus.color)
                            .font(.caption)
                        Text(task.forStatus.rawValue)
                    }
                }
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
    }
}
