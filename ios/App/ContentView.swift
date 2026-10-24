import SwiftUI

struct ContentView: View {
    /// MyMu account shown in the Chat section (nil = not signed in) and the
    /// sign-out action — the chat drawer has no account menu of its own.
    var mymuUser: String? = nil
    var onMyMuSignOut: (() -> Void)? = nil
    @State private var showQRLogin = false
    @State private var showBugReport = false
    @AppStorage("gadkURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var gadkURL: String = SharedConfig.defaultGadk
    @AppStorage("chatURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var chatURL: String = SharedConfig.defaultChat
    // MyMu access (2026-10-23): host + the agent the Chat tab opens; both come
    // from the voice server's /config and are only shown/overridable here.
    @AppStorage("mymuHost", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var mymuHost: String = "https://code.kaxtus.com"
    @AppStorage("mymuAgent", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var mymuAgent: String = "special-agent"

    var body: some View {
        NavigationView {
            Form {
                Section("Voice brain (gadk)") {
                    Button {
                        showQRLogin = true
                    } label: {
                        Label("Scan QR code to log in", systemImage: "qrcode.viewfinder")
                    }
                    TextField("https://agent.kaxtus.com/voice?app=manar&token=…", text: $gadkURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("The voice assistant the critter talks to. Scan your QR from the server's admin page, or paste the FULL tokenized URL (app + token). Applies immediately — the app refreshes itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Chat (MyMu)") {
                    TextField("https://code.kaxtus.com", text: $mymuHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let u = mymuUser {
                        HStack {
                            Label("Signed in as \(u)", systemImage: "person.crop.circle.badge.checkmark")
                            Spacer()
                            Button("Sign out", role: .destructive) { onMyMuSignOut?() }
                        }
                    }
                    Text("The MyMu host. The chat under the swarm signs in with your MyMu username and password and opens \(mymuAgent)'s conversation — that's all it needs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Memory") {
                    NavigationLink {
                        ScreenpipeView()
                    } label: {
                        Label("Screenpipe — screen & mic", systemImage: "display.and.arrow.down")
                    }
                    Text("Tap to start whole-screen broadcast + microphone into your searchable memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Support") {
                    Button {
                        showBugReport = true
                    } label: {
                        Label("Report a problem", systemImage: "ladybug")
                    }
                    Text("Sends your description plus the app's recent internal event trail to the server — crashes report themselves automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI Assistant")
            .sheet(isPresented: $showQRLogin) {
                QRLoginView { scanned in gadkURL = scanned }
            }
            .sheet(isPresented: $showBugReport) {
                BugReportView()
            }
        }
    }
}

#Preview { ContentView() }

// MARK: - The Screenpipe massam
// The capture massam, deliberately LEAN (Manar 2026-09-20: "make it a massam —
// I click it, I see Screen Broadcast, that's it; no control server"). Server +
// token are BAKED at build (SharedConfig defaults) — no config UI here, per the
// rule that a massam box has no settings. Just the two capture switches:
// whole-device screen (front and centre) and the microphone.
//
// NOTE: this build ships WITHOUT the App Group (headless provisioning can't
// register it), so the cross-process CaptureStats counters are unavailable and
// the main app genuinely cannot observe the broadcast extension's state. We
// therefore show NO "Broadcasting/Not broadcasting" label — it would be blind
// and misleading (it always read "Not broadcasting" even while live). The
// truthful indicator is iOS's own red status pill. The microphone runs IN this
// process, so its live status below is real.
struct ScreenpipeView: View {
    @ObservedObject private var audio = AudioStreamer.shared

    var body: some View {
        Form {
            // ---- SCREEN (the point of this massam — first thing you see) ----
            Section("Screen broadcast") {
                BroadcastPickerView(extensionBundleID: SharedConfig.extensionBundleID)
                    .frame(height: 56)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Tap → “Start Broadcast” (it goes straight to this app now — no app list). Streams your whole screen into searchable memory; keeps going across other apps, pauses only when the display is off. iOS shows a red pill at the top while it’s live.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ---- MICROPHONE ------------------------------------------------
            Section("Microphone") {
                Toggle("Record microphone", isOn: Binding(
                    get: { audio.isStreaming },
                    set: { $0 ? audio.userStart() : audio.userStop() }))
                statusRow(dot: audio.connected ? .green : .gray,
                          label: audio.connected ? "Uploading" : (audio.isStreaming ? "Recording" : "Off"),
                          detail: String(format: "%.0f KB", audio.sentKB))
                Text("Records continuously (also backgrounded / screen-locked) into your searchable memory. Opt-in; the choice persists.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Screenpipe")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: helpers
    @ViewBuilder private func statusRow(dot: Color, label: String, detail: String) -> some View {
        HStack {
            Circle().fill(dot).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(detail).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
