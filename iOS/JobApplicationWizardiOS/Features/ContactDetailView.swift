import SwiftUI
import JobApplicationShared

struct ContactDetailView: View {
    let contact: Contact

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue.opacity(0.6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name.isEmpty ? "Unknown" : contact.name)
                            .font(.title3)
                            .fontWeight(.semibold)
                        if !contact.title.isEmpty {
                            Text(contact.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if contact.connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if !contact.email.isEmpty || !contact.linkedin.isEmpty {
                Section("Contact Info") {
                    if !contact.email.isEmpty {
                        HStack {
                            Label(contact.email, systemImage: "envelope")
                                .font(.subheadline)
                            Spacer()
                            if let url = URL(string: "mailto:\(contact.email)") {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    if !contact.linkedin.isEmpty {
                        HStack {
                            Label(contact.linkedin, systemImage: "link")
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            if let url = URL(string: contact.linkedin.hasPrefix("http") ? contact.linkedin : "https://\(contact.linkedin)") {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }

            if !contact.notes.isEmpty {
                Section("Notes") {
                    Text(contact.notes)
                }
            }
        }
        .navigationTitle(contact.name.isEmpty ? "Contact" : contact.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
