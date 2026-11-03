package com.manarz.myagent.opener

import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.core.app.NotificationCompat
import com.manarz.myagent.R
import com.manarz.myagent.capture.CaptureState
import com.manarz.myagent.capture.ScreenCaptureService
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.Net
import com.manarz.myagent.core.Notify
import com.manarz.myagent.core.Target
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Quick Settings "Opener" tile — the Android counterpart of the iOS Control
 * Center button (OpenerControl/WriteOpenerIntent): reads the live screen
 * capture frame server-side (GET /screen/opener?which=Hinge&agent=<this phone>),
 * copies the opener to the clipboard and notifies. No app switch.
 */
class OpenerTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE   // always tappable: it nudges when the screen isn't recorded
            label = "Opener"
            updateTile()
        }
    }

    override fun onClick() {
        val t = Target.current()
        if (!t.hasToken) return notify("ProAgent", "Open MyAgent and log in first.")
        if (!CaptureState.screenRunning.value) {
            ScreenCaptureService.nudgeRestart(this, "ProAgent — your screen isn't being recorded",
                "Tap to start the screen recording, then press Opener again.")
            return
        }
        qsTile?.apply { state = Tile.STATE_ACTIVE; updateTile() }
        notify("🔎 ProAgent", "Reading your screen…")
        Beacon.send("opener-tile")
        thread(name = "opener") {
            val (title, body) = try {
                val http = Net.http.newBuilder().readTimeout(12, TimeUnit.SECONDS).build()
                http.newCall(Request.Builder()
                    .url(t.url("/screen/opener", "which" to "Hinge", "agent" to Config.screenpipeAgentId))
                    .header("Accept", "application/json").build()).execute().use { r ->
                    val obj = runCatching { JSONObject(r.body!!.string()) }.getOrDefault(JSONObject())
                    val opener = obj.optString("opener")
                    val ctx = obj.optJSONObject("context")
                    val from = listOf(ctx?.optString("app").orEmpty(), obj.optString("agent")).filter { it.isNotEmpty() }
                        .joinToString(" · ")
                    when {
                        obj.optBoolean("needs_broadcast") || (obj.has("connected") && !obj.optBoolean("connected")) ->
                            "ProAgent — your screen isn't being recorded" to (obj.optString("reason").ifEmpty {
                                "Start the screen recording in MyAgent, then press the tile again." })
                        r.code == 200 && opener.isNotEmpty() -> {
                            getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Opener", opener))
                            ("✨ Opener copied — paste into Hinge" + if (from.isNotEmpty()) "  (read: $from)" else "") to opener
                        }
                        else -> "ProAgent — nothing to copy" to (obj.optString("reason").ifEmpty {
                            "Nothing to write — is the screen recording running on this screen?" } +
                            if (from.isNotEmpty()) "  (read: $from)" else "")
                    }
                }
            } catch (e: Exception) {
                "ProAgent — couldn't reach the server" to "Check your connection + that the screen recording is running."
            }
            notify(title, body)
            qsTile?.apply { state = Tile.STATE_INACTIVE; updateTile() }
        }
    }

    private fun notify(title: String, body: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(FEED_ID, NotificationCompat.Builder(this, Notify.CH_AGENT)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body.take(300))
            .setStyle(NotificationCompat.BigTextStyle().bigText(body.take(300)))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(ScreenCaptureService.openScreenpipe(this))
            .setAutoCancel(true)
            .build())
    }

    companion object { private const val FEED_ID = 45 }
}
