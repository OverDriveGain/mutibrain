import SwiftUI

struct ContentView: View {
    @ObservedObject private var audio = AudioStreamer.shared
    @State private var showQRLogin = false
    @State private var showBugReport = false
    @AppStorage("serverBase", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var serverBase: String = SharedConfig.defaultBase
    @AppStorage("token", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var token: String = SharedConfig.defaultToken
    @AppStorage("agentId", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var agentId: String = SharedConfig.defaultAgentId
    @AppStorage("gadkURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var gadkURL: String = SharedConfig.defaultGadk
    @AppStorage("chatURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var chatURL: String = SharedConfig.defaultChat

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
                    Text("The voice assistant the critter talks to. Scan your QR from the server's admin page, or paste the FULL tokenized URL (app + token). Restart the app after changing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Chat (MyMu)") {
                    TextField("https://code.kaxtus.com/?token=…", text: $chatURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("MyMu agent-view share link for the Chat tab. Paste a token URL to open a different agent's conversation. Restart the app after changing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Memory (screenpipe)") {
                    TextField("http://host:8090", text: $serverBase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("agent id", text: $agentId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Agent token (spk_…)", text: $token)
                    Text("Screen capture runs in a separate process and uses the values built into the app; these fields are a convenience and apply to the app only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Microphone") {
                    HStack {
                        Circle()
                            .fill(audio.connected ? .green : .gray)
                            .frame(width: 10, height: 10)
                        Text(audio.connected ? "Connected" : "Offline")
                        Spacer()
                        Text(String(format: "%.0f KB sent", audio.sentKB))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button(audio.isStreaming ? "Stop microphone" : "Start microphone") {
                        audio.isStreaming ? audio.userStop() : audio.userStart()
                    }
                    .tint(audio.isStreaming ? .red : .accentColor)
                    Text("The microphone starts automatically with the app and keeps recording (also in the background) until stopped here.")
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

                Section("Whole-device screen") {
                    Text("Tap below, then choose “Start Broadcast”. Capture continues across other apps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    BroadcastPickerView(extensionBundleID: SharedConfig.extensionBundleID)
                        .frame(height: 56)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Section {
                    Text("Start Broadcast to stream whole-device screen frames to screenpipe (the server OCRs + indexes them for search). Capture continues across other apps and pauses only when the display is fully off. Microphone → screenpipe audio is coming next.")
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
