package com.manarz.myagent.capture

import android.app.Activity
import android.content.Context
import android.media.projection.MediaProjectionManager
import android.webkit.WebView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material.icons.filled.StopScreenShare
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.foundation.selection.toggleable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Target
import com.manarz.myagent.home.CritterController
import com.manarz.myagent.home.makeCritterWebView

/** Screenpipe memory: whole-screen capture + always-on mic (iOS broadcast extension + AudioStreamer). */
object CaptureModule {
    fun init(ctx: Context) {}

    /** Called on the home's first appearance (iOS AudioStreamer.autoStartIfEnabled). */
    fun autoStart(ctx: Context) {
        if (MicCaptureService.enabled && !CaptureState.micRunning.value) {
            Beacon.send("sp-mic-autostart")
            MicCaptureService.start(ctx)
        }
    }
}

/** Starts the screen-capture consent flow from an Activity (the home's one-tap Screen button). */
object ScreenConsent { var request: (() -> Unit)? = null }

/**
 * Registers the MediaProjection consent launcher for the activity it's mounted in
 * and publishes it as [ScreenConsent.request]; on OK the capture service starts with
 * the (single-use) consent token. Mount once, in the activity's root.
 */
@Composable
fun ScreenConsentHost() {
    val ctx = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val data = r.data
        if (r.resultCode == Activity.RESULT_OK && data != null) ScreenCaptureService.start(ctx.applicationContext, r.resultCode, data)
        else Beacon.send("bcast-consent-declined")
    }
    DisposableEffect(launcher) {
        val mpm = ctx.getSystemService(MediaProjectionManager::class.java)
        ScreenConsent.request = {
            // whole-device memory (iOS broadcasts the entire screen): ask for the default
            // display up front instead of Android 14's "share one app" default
            launcher.launch(if (android.os.Build.VERSION.SDK_INT >= 34)
                mpm.createScreenCaptureIntent(android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay())
            else mpm.createScreenCaptureIntent())
        }
        onDispose { ScreenConsent.request = null }
    }
}

private val Muted = Color.White.copy(alpha = 0.55f)
private val Card = Color(0xFF15141E)
private val Accent = Color(0xFF8E7BFF)

/**
 * The Screenpipe page (iOS ScreenpipeView): the screen capture front and centre,
 * the web Screen panel (suggest · search · live capture), and the mic switch.
 * Unlike iOS, capture runs in-process, so the screen status shown here is real.
 */
@Composable
fun ScreenpipeScreen(modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    var panel by remember { mutableStateOf(false) }
    if (panel) { ScreenPanel(onBack = { panel = false }, modifier); return }

    val screenOn by CaptureState.screenRunning.collectAsState()
    val sent by CaptureState.screenSent.collectAsState()
    val failed by CaptureState.screenFailed.collectAsState()
    val err by CaptureState.lastError.collectAsState()
    val micOn by CaptureState.micRunning.collectAsState()
    val micUp by CaptureState.micConnected.collectAsState()
    val kb by CaptureState.micSentKB.collectAsState()

    Column(modifier.fillMaxSize().background(Color(0xFF050608)).statusBarsPadding()
        .verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text("Screenpipe", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)

        Section("Screen recording") {
            Button(
                onClick = {
                    if (screenOn) ScreenCaptureService.stop(ctx)
                    else ScreenConsent.request?.invoke() ?: Beacon.send("bcast-no-consent-host")
                },
                colors = ButtonDefaults.buttonColors(containerColor = if (screenOn) Color(0xFF3A2430) else Accent),
                modifier = Modifier.fillMaxWidth().height(52.dp),
            ) {
                Icon(if (screenOn) Icons.Filled.StopScreenShare else Icons.Filled.ScreenShare, null)
                Spacer(Modifier.width(8.dp))
                Text(if (screenOn) "Stop screen recording" else "Start screen recording")
            }
            StatusRow(if (screenOn) Color(0xFF3DDC84) else Color.Gray,
                if (screenOn) "Recording" else "Off", "$sent sent" + if (failed > 0) " · $failed failed" else "")
            err?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 12.sp) }
            Hint("Tap → “Start now”. Streams your whole screen (and audio other apps play) into searchable memory; keeps going across apps. Android shows the cast icon while it’s live — stop it there or here.")
        }

        Section("Screen memory") {
            Row(Modifier.fillMaxWidth().clickable { panel = true }.padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.AutoAwesome, null, tint = Accent)
                Text("Suggest · Search · Live capture", color = Color.White, modifier = Modifier.weight(1f).padding(start = 12.dp))
                Icon(Icons.Filled.ChevronRight, null, tint = Muted)
            }
        }

        // Samsung / One UI put background apps to sleep and kill long-running capture;
        // the standard exemption keeps memory recording (no iOS equivalent needed there)
        val pm = ctx.getSystemService(android.os.PowerManager::class.java)
        var exempt by remember { mutableStateOf(pm.isIgnoringBatteryOptimizations(ctx.packageName)) }
        val life = androidx.compose.ui.platform.LocalLifecycleOwner.current
        DisposableEffect(life) {
            val o = androidx.lifecycle.LifecycleEventObserver { _, e ->
                if (e == androidx.lifecycle.Lifecycle.Event.ON_RESUME) exempt = pm.isIgnoringBatteryOptimizations(ctx.packageName)
            }
            life.lifecycle.addObserver(o); onDispose { life.lifecycle.removeObserver(o) }
        }
        if (!exempt) Section("Keep recording in the background") {
            Row(Modifier.fillMaxWidth().clickable {
                runCatching {
                    ctx.startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        android.net.Uri.parse("package:${ctx.packageName}")))
                }
            }, verticalAlignment = Alignment.CenterVertically) {
                Text("Allow MyAgent to run in the background", color = Color.White, modifier = Modifier.weight(1f))
                Icon(Icons.Filled.ChevronRight, null, tint = Muted)
            }
            Hint("Android's battery saver can stop screen and mic memory after a while. Allow it once and recording keeps going.")
        }

        Section("Microphone") {
            // the whole row toggles, like an iOS Toggle row
            Row(Modifier.fillMaxWidth().toggleable(value = micOn, role = androidx.compose.ui.semantics.Role.Switch) { on ->
                if (on) MicCaptureService.userStart(ctx) else MicCaptureService.userStop(ctx)
            }, verticalAlignment = Alignment.CenterVertically) {
                Text("Record microphone", color = Color.White, modifier = Modifier.weight(1f))
                Switch(checked = micOn, onCheckedChange = null, colors = SwitchDefaults.colors(checkedTrackColor = Accent))
            }
            StatusRow(if (micUp) Color(0xFF3DDC84) else Color.Gray,
                if (micUp) "Uploading" else if (micOn) "Recording" else "Off", String.format("%.0f KB", kb))
            Hint("Records continuously (also in the background / screen off) into your searchable memory. Pauses while you talk to MyMu. Opt-in; the choice persists.")
        }
    }
}

/** The embed's Screen massam alone (`#only=screen`), full-page. */
@Composable
private fun ScreenPanel(onBack: () -> Unit, modifier: Modifier) {
    val ctl = remember { CritterController() }
    Column(modifier.fillMaxSize().background(Color(0xFF050608)).statusBarsPadding()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White) }
            Text("Screen memory", color = Color.White, fontWeight = FontWeight.SemiBold)
        }
        val t = Target.current()
        AndroidView(
            factory = { c -> makeCritterWebView(c, ctl, "app=${t.app}&token=${t.token}&nochat=1&only=screen") },
            onRelease = { w: WebView -> w.destroy() },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title.uppercase(), color = Muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Card).padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
    }
}

@Composable
private fun StatusRow(dot: Color, label: String, detail: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(dot))
        Text(label, color = Color.White, modifier = Modifier.weight(1f).padding(start = 10.dp))
        Text(detail, color = Muted)
    }
}

@Composable
private fun Hint(text: String) = Text(text, color = Muted, fontSize = 12.sp)
