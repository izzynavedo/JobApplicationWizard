import SwiftUI
import JobApplicationShared

struct NoteDetailView: View {
    let note: Note

    var body: some View {
        List {
            if !note.title.isEmpty {
                Section("Title") {
                    Text(note.title)
                }
            }

            if !note.subtitle.isEmpty {
                Section("Subtitle") {
                    Text(note.subtitle)
                        .foregroundStyle(.secondary)
                }
            }

            if !note.body.isEmpty {
                Section("Note") {
                    Text(note.body)
                }
            }

            if !note.tags.isEmpty {
                Section("Tags") {
                    FlowLayout(spacing: 6) {
                        ForEach(note.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Section("Details") {
                LabeledContent("Created") {
                    Text(note.createdAt, style: .date)
                }
                LabeledContent("Updated") {
                    Text(note.updatedAt, style: .relative)
                }
            }
        }
        .navigationTitle(note.title.isEmpty ? "Note" : note.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
