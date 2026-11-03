# Vendored MyMu Android client

`app/src/main/java/com/mymu/app/{core,ui}` is the MyMu Android client
(`~/Projects/mymu/android/app/src/main/java/com/mymu/app/{core,ui}`) copied
verbatim, package kept — it IS the chat of the MyAgent app, the drawer under
the swarm (Manar 2026-10-24: "use the chat from MyMu exactly as it is"; same
rule as `ios/MyMuChat`). Do not restyle or fork it here; fix things in MyMu and
re-vendor with `scripts/vendor-mymu-android.sh`.

Last vendored: 2026-11-03 14:12 from MyMu HEAD b035b18 (+ 0 uncommitted files in its android tree).

The script re-applies the HOST PATCHES (grep "HOST PATCH"):
  * `import com.mymu.app.R` / `BuildConfig` → `com.manarz.myagent.R` /
    `.BuildConfig` (the vendored code compiles inside the host module).
  * FileProvider authority `${packageName}.fileprovider` → `${packageName}.files`
    (the host manifest's provider).
  * `core/ProjectsStore.kt` — `agentFilter` + `rosterOf()`; `agents` honours it
    (the drawer's curated swipe roster from `/config mymu.agents`, brain first —
    iOS host patch of 2026-10-30).
  * `ui/AgentSwitcher.kt` — the swipe roster reads `store.rosterOf(projects)`.

No dictation patch is needed here (iOS patches ChatView): MyMu Android already
has `ComposerInsertBus`; `com.manarz.myagent.chat.Dictation` inserts through it.

Not wired on purpose: `MainActivity` / `MyMuApplication` (the host owns the
activity and the Application — `ChatModule.init` does MyMu's init block),
`MyMuMessagingService` / `ShareActivity` (the host has its own push), the
`mymu://` scheme (QRAccess), MyMu's MainTabs (the drawer shows one conversation).
The harness logos (`harness_*.xml`) are copied into the host's `res/drawable`.
The host side lives in `com/manarz/myagent/chat/` (sign-in, which agent, dots,
peek, dictation) and `home/HomeScreen.kt` (the voice ↔ chat drawer).
