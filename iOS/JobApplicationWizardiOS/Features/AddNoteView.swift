import SwiftUI
import JobApplicationShared

/// Standalone note creation view that owns its own state.
/// Does not read from the TCA store during editing, preventing
/// re-renders that cause keyboard presentation freezes.
struct AddNoteView: View {
    let jobId: UUID
    let onSave: (Note) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var noteBody = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($titleFocused)
                }
                Section("Note") {
                    TextField("Write your note here...", text: $noteBody, axis: .vertical)
                        .lineLimit(5...20)
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let note = Note(title: title, body: noteBody)
                        onSave(note)
                    }
                    .disabled(title.isEmpty && noteBody.isEmpty)
                }
            }
            .onAppear {
                titleFocused = true
            }
        }
    }
}
