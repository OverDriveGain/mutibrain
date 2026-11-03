package com.manarz.myagent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.manarz.myagent.capture.CaptureModule
import com.manarz.myagent.capture.ScreenConsent
import com.manarz.myagent.capture.ScreenpipeScreen
import com.manarz.myagent.core.AppEvent
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.CrashReporter
import com.manarz.myagent.core.Events
import com.manarz.myagent.core.ReportClient
import com.manarz.myagent.core.ServerConfig
import com.manarz.myagent.core.Target
import com.manarz.myagent.home.Detent
import com.manarz.myagent.home.HomeScreen
import com.manarz.myagent.home.launchFileChooser
import com.manarz.myagent.home.pendingFileChooser
import com.manarz.myagent.music.MusicScreen
import com.manarz.myagent.push.PushModule
import com.manarz.myagent.settings.QrLoginScreen
import com.manarz.myagent.settings.SettingsScreen
import com.manarz.myagent.settings.validateLogin
import kotlinx.coroutines.launch
import kotlin.concurrent.thread

private val Stage = Color(0xFF050608)
private val Accent = Color(0xFF8E7BFF)

class MainActivity : ComponentActivity() {
    private val fileChooser = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val cb = pendingFileChooser; pendingFileChooser = null
        val data = r.data
        val uris: Array<Uri>? = when {
            r.resultCode != RESULT_OK || data == null -> null
            data.clipData != null -> Array(data.clipData!!.itemCount) { data.clipData!!.getItemAt(it).uri }
            data.data != null -> arrayOf(data.data!!)
            else -> null
        }
        cb?.onReceiveValue(uris)
    }
    private val askPerms = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {}

    /** A myagent://login?url=… link (or the QR URL itself) handed to the app. */
    private var deepLink by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(Color.Transparent.toArgb()),
            navigationBarStyle = SystemBarStyle.dark(Stage.toArgb()))
        super.onCreate(savedInstanceState)
        launchFileChooser = { fileChooser.launch(it) }
        askFirstRunPermissions()
        deepLink = linkFrom(intent)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Accent, background = Stage, surface = Stage)) {
                Root(deepLink) { deepLink = null }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        linkFrom(intent)?.let { deepLink = it }
        if (intent.getBooleanExtra(EXTRA_SCREENPIPE, false)) Events.post(AppEvent.ShowScreenpipe(present = false))
    }

    override fun onResume() {
        super.onResume()
        CrashReporter.heartbeat()
        ReportClient.flush()
        thread(name = "config-sync") { ServerConfig.sync() }
        PushModule.reregister()
    }

    private fun linkFrom(i: Intent?): String? {
        val u = i?.data ?: return null
        return if (u.scheme == "myagent") u.getQueryParameter("url") else u.toString()
    }

    private fun askFirstRunPermissions() {
        val want = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (want.isNotEmpty()) askPerms.launch(want.toTypedArray())
    }

    companion object { const val EXTRA_SCREENPIPE = "screenpipe" }
}

private enum class Overlay { NONE, SETTINGS, QR, SCREENPIPE }

@Composable
private fun Root(deepLink: String?, consumeLink: () -> Unit) {
    val gadk by Config.gadkFlow.collectAsState()
    val scope = rememberCoroutineScope()
    var overlay by remember { mutableStateOf(Overlay.NONE) }
    var linkMsg by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(deepLink) {
        val l = deepLink ?: return@LaunchedEffect
        // validate in the outer scope: consuming the link re-keys (cancels) this effect
        scope.launch { validateLogin(l).fold(onSuccess = { Config.gadkURL = it; linkMsg = null }, onFailure = { linkMsg = it.message }) }
        consumeLink()
    }
    LaunchedEffect(Unit) {
        Events.flow.collect { e ->
            if (e is AppEvent.ShowScreenpipe) {
                if (e.present && ScreenConsent.request != null) ScreenConsent.request?.invoke() else overlay = Overlay.SCREENPIPE
            }
        }
    }

    BackHandler(overlay != Overlay.NONE) {
        overlay = if (overlay == Overlay.QR || overlay == Overlay.SCREENPIPE) Overlay.SETTINGS else Overlay.NONE
    }

    // a new login rebuilds everything in place (iOS .id(gadkURL)) — no restart
    key(gadk) {
        Box(Modifier.fillMaxSize().background(Stage)) {
            if (!Target.from(gadk).hasToken) {
                Welcome(linkMsg, onScan = { overlay = Overlay.QR }) { url ->
                    scope.launch { validateLogin(url).fold(onSuccess = { Config.gadkURL = it }, onFailure = { linkMsg = it.message }) }
                }
            } else {
                Tabs(onSettings = { overlay = Overlay.SETTINGS })
            }
            when (overlay) {
                Overlay.SETTINGS -> SettingsScreen(
                    onClose = { overlay = Overlay.NONE },
                    onScanQr = { overlay = Overlay.QR },
                    onScreenpipe = { overlay = Overlay.SCREENPIPE })
                Overlay.QR -> QrLoginScreen(onLogin = { Config.gadkURL = it; overlay = Overlay.NONE },
                    onClose = { overlay = Overlay.NONE })
                Overlay.SCREENPIPE -> Box(Modifier.fillMaxSize().background(Stage)) { ScreenpipeScreen() }
                Overlay.NONE -> {}
            }
        }
    }
}

@Composable
private fun Tabs(onSettings: () -> Unit) {
    var tab by rememberSaveable { mutableStateOf(0) }
    var detent by rememberSaveable { mutableStateOf(Detent.CLOSED) }
    LaunchedEffect(Unit) { CaptureModule.autoStart(com.manarz.myagent.core.AppContext.get()) }
    Column(Modifier.fillMaxSize().imePadding()) {
        Box(Modifier.weight(1f)) {
            when (tab) {
                0 -> HomeScreen(detent, { detent = it }, onSettings)
                else -> MusicScreen()
            }
        }
        // the tab bar leaves while the drawer is open (a conversation is full-screen content)
        if (tab != 0 || detent == Detent.CLOSED) {
            NavigationBar(containerColor = Stage, tonalElevation = 0.dp) {
                listOf(Icons.Filled.Mic to "Talk", Icons.Filled.MusicNote to "Music").forEachIndexed { i, (icon, label) ->
                    NavigationBarItem(selected = tab == i, onClick = { tab = i },
                        icon = { Icon(icon, label) },
                        colors = NavigationBarItemDefaults.colors(selectedIconColor = Color.White,
                            unselectedIconColor = Color.White.copy(alpha = 0.45f), indicatorColor = Accent.copy(alpha = 0.25f)))
                }
            }
        }
    }
}

/** First run: no subscriber yet — scan the QR from /admin, or paste the link. */
@Composable
private fun Welcome(msg: String?, onScan: () -> Unit, onPaste: (String) -> Unit) {
    var url by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text("MyAgent", color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        Text("Scan the login QR from your assistant's admin page to connect.", color = Color.White.copy(alpha = 0.6f),
            textAlign = TextAlign.Center)
        Spacer(Modifier.height(28.dp))
        Button(onClick = onScan, colors = ButtonDefaults.buttonColors(containerColor = Accent),
            modifier = Modifier.fillMaxWidth().height(52.dp)) {
            Icon(Icons.Filled.QrCodeScanner, null); Spacer(Modifier.padding(4.dp)); Text("Scan QR code")
        }
        Spacer(Modifier.height(22.dp))
        OutlinedTextField(url, { url = it }, singleLine = true, label = { Text("…or paste the login link") },
            modifier = Modifier.fillMaxWidth())
        if (url.isNotBlank()) TextButton(onClick = { onPaste(url) }) { Text("Connect") }
        msg?.let { Spacer(Modifier.height(12.dp)); Text(it, color = Color(0xFFFF6B6B), textAlign = TextAlign.Center) }
    }
}
