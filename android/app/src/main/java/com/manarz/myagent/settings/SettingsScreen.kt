package com.manarz.myagent.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.manarz.myagent.BuildConfig
import com.manarz.myagent.chat.ChatModule
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.ReportClient
import kotlinx.coroutines.launch

private val Muted = Color.White.copy(alpha = 0.55f)
private val Card = Color(0xFF15141E)

/** Settings (iOS ContentView): voice login, MyMu host, screen & mic memory, report a problem. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onClose: () -> Unit, onScanQr: () -> Unit, onScreenpipe: () -> Unit) {
    val scope = rememberCoroutineScope()
    var gadk by remember { mutableStateOf(Config.gadkURL) }
    var gadkMsg by remember { mutableStateOf<String?>(null) }
    var host by remember { mutableStateOf(Config.mymuHost) }
    var showBug by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = Color(0xFF050608),
        topBar = {
            TopAppBar(
                title = { Text("MyAgent", color = Color.White) },
                navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color(0xFF050608)),
            )
        },
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp)) {

            Section("Voice brain") {
                Row(Icons.Filled.QrCodeScanner, "Scan QR code to log in", onClick = onScanQr)
                OutlinedTextField(gadk, { gadk = it; gadkMsg = null }, singleLine = true,
                    label = { Text("https://agent.kaxtus.com/voice?app=…&token=…") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.fillMaxWidth())
                if (gadk != Config.gadkURL) TextButton(onClick = {
                    scope.launch {
                        validateLogin(gadk).fold(
                            onSuccess = { Config.gadkURL = it; gadkMsg = "Saved — the app refreshed itself" },
                            onFailure = { gadkMsg = it.message })
                    }
                }) { Text("Save") }
                gadkMsg?.let { Text(it, color = Muted, fontSize = 12.sp) }
                Hint("The voice assistant the swarm talks to. Scan your QR from the server's admin page, or paste the FULL tokenized URL (app + token).")
            }

            Section("Chat (MyMu)") {
                OutlinedTextField(host, { host = it; Config.mymuHost = it }, singleLine = true,
                    label = { Text("https://code.kaxtus.com") }, modifier = Modifier.fillMaxWidth())
                ChatModule.user?.let { u ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Signed in as $u", color = Color.White, modifier = Modifier.weight(1f))
                        TextButton(onClick = { ChatModule.signOut() }) { Text("Sign out", color = Color(0xFFFF6B6B)) }
                    }
                }
                Hint("The chat under the swarm signs in with your MyMu username and password and opens ${Config.mymuAgent}'s conversation.")
            }

            Section("Memory") {
                Row(Icons.Filled.ScreenShare, "Screenpipe — screen & mic", onClick = onScreenpipe)
                Hint("Whole-screen capture + microphone into your searchable memory.")
            }

            Section("Support") {
                Row(Icons.Filled.BugReport, "Report a problem") { showBug = true }
                Hint("Sends your description plus the app's recent internal event trail — crashes report themselves.")
            }
            Text("MyAgent ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", color = Muted, fontSize = 12.sp,
                modifier = Modifier.align(Alignment.CenterHorizontally))
        }
    }
    if (showBug) BugReportDialog { showBug = false }
}

@Composable
private fun BugReportDialog(onDone: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Report a problem") },
        text = {
            Column {
                OutlinedTextField(text, { text = it }, minLines = 4, placeholder = { Text("What happened?") })
                msg?.let { Text(it, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(enabled = text.isNotBlank() && !sending, onClick = {
                sending = true
                ReportClient.submit(kind = "bug", text = text) { ok ->
                    sending = false
                    if (ok) onDone() else msg = "Queued — it will send when the server is reachable"
                }
            }) { Text("Send") }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
    )
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
private fun Row(icon: ImageVector, label: String, onClick: () -> Unit) {
    androidx.compose.foundation.layout.Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Color(0xFF8E7BFF))
        Spacer(Modifier.height(0.dp).padding(start = 12.dp))
        Text(label, color = Color.White, modifier = Modifier.weight(1f).padding(start = 12.dp))
        Icon(Icons.Filled.ChevronRight, null, tint = Muted)
    }
}

@Composable
private fun Hint(text: String) = Text(text, color = Muted, fontSize = 12.sp)
