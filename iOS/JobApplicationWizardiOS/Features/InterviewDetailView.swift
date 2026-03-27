import SwiftUI
import JobApplicationShared

struct InterviewDetailView: View {
    let interview: InterviewRound

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Round \(interview.round)")
                            .font(.title2)
                            .fontWeight(.bold)
                        if !interview.type.isEmpty {
                            Text(interview.type)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if interview.completed {
                        Label("Completed", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    } else {
                        Label("Upcoming", systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Schedule") {
                if let date = interview.date {
                    LabeledContent("Date") {
                        Text(date, style: .date)
                    }
                    LabeledContent("Time") {
                        Text(date, style: .time)
                    }
                    LabeledContent("In") {
                        Text(date, style: .relative)
                    }
                } else {
                    Text("No date scheduled")
                        .foregroundStyle(.tertiary)
                }
            }

            if !interview.interviewers.isEmpty {
                Section("Interviewers") {
                    ForEach(interview.interviewers.components(separatedBy: ","), id: \.self) { name in
                        Label(name.trimmingCharacters(in: .whitespaces), systemImage: "person")
                    }
                }
            }

            if !interview.notes.isEmpty {
                Section("Notes") {
                    Text(interview.notes)
                }
            }

            if let eventTitle = interview.calendarEventTitle {
                Section("Calendar") {
                    Label(eventTitle, systemImage: "calendar")
                }
            }
        }
        .navigationTitle("Round \(interview.round)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
