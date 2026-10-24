import SwiftUI
import UIKit

@main
struct AIAssistantApp: App {
    @Environment(\.scenePhase) private var scenePhase
    // APNs: request auth, register for remote notifications, handle the
    // background Copy action for agent text shares (see PushNotifications.swift).
    @UIApplicationDelegateAdaptor(PushNotifications.self) private var pushDelegate
    // The subscriber the app is logged in as (tokenized voice URL). Changing
    // it — QR login or manual edit — rebuilds every tab live via .id() below,
    // so a fresh login needs NO app restart.
    @AppStorage("gadkURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var gadkURL: String = SharedConfig.defaultGadk

    init() {
        CrashReporter.install()
        // If the previous run died, report what killed it (journal beacon +
        // a structured POST /report with the death-context breadcrumbs).
        CrashReporter.reportIfCrashed()
        // Build tag: proves in the journal WHICH build is on the phone (we
        // once spent a session debugging an old build believed new).
        GadkVoice.beacon(AppBuild.tag)
        ReportClient.flush()   // deliver anything still queued from offline runs
        ChatURLSync.run()      // server-driven Chat tab token (voice /config)
        // Dark tab bar (Manar 2026-07-28): the iOS floating glass tab bar read
        // PURPLE off the content behind it — pin it to a solid near-black so the
        // bottom bar is never purple regardless of what's on screen.
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor(red: 0.02, green: 0.024, blue: 0.031, alpha: 1) // #050608
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                PetView()
                    .tabItem { Image(systemName: "mic.fill") }   // icon only, no label
                    .onAppear {
                        // Ops/verification hook: launch with env SPMIC_FORCE=1
                        // (e.g. `devicectl device process launch --environment
                        // SPMIC_FORCE=1 …`) to enable + start the screenpipe
                        // always-on mic headlessly. Harmless otherwise — the
                        // recorder stays strictly opt-in (Manar, 2026-07-15).
                        if ProcessInfo.processInfo.environment["SPMIC_FORCE"] == "1" {
                            AudioStreamer.shared.userStart()
                        } else {
                            AudioStreamer.shared.autoStartIfEnabled()
                        }
                    }
                // The Chat tab is GONE (2026-10-24): the MyMu conversation with
                // the brain now lives IN the Buddy screen, as the drawer under
                // the swarm (PetView / ChatDrawer) — one place, one chat.
                MusicView()
                    .tabItem { Image(systemName: "music.note") }
            }
            .id(gadkURL)  // new login → tear down + rebuild all tabs in place
            .onChange(of: gadkURL) { _ in
                ChatURLSync.run()  // the Chat tab token follows the new subscriber
                PushNotifications.shared.reregisterCurrentSubscriber()  // shares follow too
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    ReportClient.flush()  // retry queued reports
                    ChatURLSync.run()     // pick up server-side chat-token rotations
                    PushNotifications.shared.reregisterCurrentSubscriber()
                }
            }
        }
    }
}
