import SwiftUI

/// "Report a problem" — the user describes what went wrong; the report goes
/// to the voice server's POST /report with the app's recent breadcrumb trail
/// and device info attached. Queued + retried if offline, like crash reports.
struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var result: String?

    var body: some View {
        NavigationView {
            Form {
                Section("What happened?") {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                    Text("Include what you did and what you expected. The app attaches its recent internal events automatically — no logs needed from you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let result {
                    Section { Text(result).font(.callout) }
                }
                Section {
                    Button {
                        send()
                    } label: {
                        if sending { ProgressView() } else { Text("Send report") }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func send() {
        sending = true
        result = nil
        ReportClient.submit(kind: "bug",
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines)) { ok in
            sending = false
            result = ok ? "Sent — thank you! The developer sees it with full context."
                        : "Saved on the phone — it will be delivered automatically once the server is reachable."
            if ok {
                text = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
            }
        }
    }
}
