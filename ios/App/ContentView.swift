import SwiftUI

struct ContentView: View {
    @StateObject private var audio = AudioStreamer()
    @AppStorage("serverBase", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var serverBase: String = SharedConfig.defaultBase
    @AppStorage("token", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var token: String = SharedConfig.defaultToken
    @AppStorage("agentId", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var agentId: String = SharedConfig.defaultAgentId
    @AppStorage("gadkURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var gadkURL: String = SharedConfig.defaultGadk

    var body: some View {
        NavigationView {
            Form {
                Section("Voice brain (gadk)") {
                    TextField("https://gadk.kaxtus.com/voice", text: $gadkURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("The voice assistant the pet talks to. Restart the app after changing.")
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
                        audio.isStreaming ? audio.stop() : audio.start()
                    }
                    .tint(audio.isStreaming ? .red : .accentColor)
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
        }
    }
}

#Preview { ContentView() }
