import SwiftUI

struct ContentView: View {
    @StateObject private var audio = AudioStreamer()
    @AppStorage("serverBase", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var serverBase: String = "ws://192.168.1.10:8000"
    @AppStorage("token", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var token: String = "dev-secret-token"

    var body: some View {
        NavigationView {
            Form {
                Section("Server") {
                    TextField("ws://host:port", text: $serverBase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Token", text: $token)
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
                    Text("Mic keeps streaming while backgrounded or locked. Screen capture pauses only when the display is fully off (nothing is being rendered).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI Assistant")
        }
    }
}

#Preview { ContentView() }
