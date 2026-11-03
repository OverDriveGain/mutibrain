package com.mymu.app.core

import android.content.Intent
import com.manarz.myagent.BuildConfig // HOST PATCH: host BuildConfig

/**
 * UI-test launch hooks — the Android form of the launch environment the iOS
 * XCUITests set (MYMU_RESET / MYMU_DEMO / MYMU_DEMO_STREAM, read in MyMuApp):
 * intent extras on MainActivity, read once in onCreate BEFORE the UI composes,
 * honored in DEBUG builds only. A release build ignores them entirely.
 *
 *   mymu.reset=1              forget every login + cached conversation first
 *   mymu.demo=chat|chatlong   boot straight into an offline demo chat (the
 *                             5-row DemoData.messages, or the long one)
 *   mymu.demo.stream=1|short|block  1.2s after that chat opens, simulate a SEND: the
 *                             view choreography plus a whole fake turn through
 *                             the relay's real inbound path
 *                             (RelayClient.simulateTurn); `short` is a reply
 *                             that leaves blank space under the turn;
 *                             `block` delivers the reply as ONE text frame
 *                             (the relay's shape) — the paced-reveal stage
 *
 * By hand: `adb shell am start -n com.mymu.app/.MainActivity
 *            --es mymu.demo chatlong --es mymu.demo.stream 1`.
 */
object UiTestHooks {
    const val EXTRA_RESET = "mymu.reset"
    const val EXTRA_DEMO = "mymu.demo"
    const val EXTRA_DEMO_STREAM = "mymu.demo.stream"

    /** "chat" / "chatlong", or null for the regular app. */
    var demo: String? = null
        private set
    private var stream: String? = null

    /** "1" / "short" — only meaningful inside a `demo` launch. */
    val demoStream: String? get() = if (demo != null) stream else null

    fun read(intent: Intent?) {
        if (!BuildConfig.DEBUG) return
        demo = intent?.getStringExtra(EXTRA_DEMO)?.takeIf { it == "chat" || it == "chatlong" }
        stream = intent?.getStringExtra(EXTRA_DEMO_STREAM)?.takeIf { it == "1" || it == "short" || it == "block" }
        if (intent?.getStringExtra(EXTRA_RESET) == "1") AppState.wipeForUITests()
    }

    /** The transcript the demo chat opens with; null = the regular demo rows. */
    fun demoTranscript(): List<ChatMessage>? = if (demo == "chatlong") DemoData.longMessages else null

    // The simulated turn (iOS ChatView.simPrompt / simReply / simReplyShort).
    const val simPrompt = "Question number 24: can you look into part 24 of the module and explain what it does in detail?"
    val simReply = """
        Part 24 is the reconciliation path. It takes the raw input, normalizes it, and returns a typed result, but unlike the earlier parts it also has to agree with whatever the previous pass already produced, which is where most of its complexity lives.

        The first half walks the incoming records in order and matches each one against the known set by id. A match replaces the known record in place, so position is preserved and nothing visibly moves. A miss is appended at the end, and a record that the known set has but the input lacks is kept rather than dropped, because the input can legitimately lag behind.

        The second half handles the id-less case: chunks that arrive without a stable identity are matched as a running prefix of the newest known record, and only the part that extends past it is treated as new. If the chunk diverges, everything that was provisionally swallowed is restored, so the worst case is a missed animation rather than lost text.

        The tricky bit is the fallback branch that runs when the primary source is unavailable. It retries with a shorter timeout, then falls back to the last persisted snapshot, and then degrades gracefully.
    """.trimIndent()
    /** A reply that leaves blank space under the active turn — the stage for
     * "opening the composer must not move the last message". */
    const val simReplyShort = "Part 24 is the reconciliation path: it normalizes the input and agrees with the previous pass."

    /** DEBUG demo runs only: what the paced reveal did, in order —
     * "reveal:<chars shown>" per step and "row:<kind>:<tool>" per new row.
     * Compose test sync waits out the reveal's ticks, so the instrumented
     * test reads this instead of sampling the screen. */
    val revealTrace: MutableList<String> = java.util.Collections.synchronizedList(mutableListOf())

    fun trace(event: String) {
        if (BuildConfig.DEBUG && demo != null) revealTrace.add(event)
    }
}
