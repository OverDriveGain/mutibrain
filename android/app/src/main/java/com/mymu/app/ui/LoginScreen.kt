package com.mymu.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mymu.app.core.AppState
import com.mymu.app.core.Config
import com.mymu.app.core.LoginHistory
import com.mymu.app.core.LoginMemory
import kotlinx.coroutines.launch

/**
 * Port of iOS LoginView. `initialOrigin` is deliberately NOT defaulted to the
 * active host — "Add account" passes null (empty field, an explicit choice);
 * the root login and re-auth pass the host they mean.
 */
@Composable
fun LoginScreen(
    initialOrigin: String? = null,
    initialUsername: String? = null,
    notice: String? = null,
    onSuccess: (() -> Unit)? = null,
    onCancel: (() -> Unit)? = null,
) {
    var serverOrigin by remember { mutableStateOf(initialOrigin ?: "") }
    var username by remember { mutableStateOf(initialUsername ?: "") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var showScanner by remember { mutableStateOf(false) }
    // Past successful logins (host + user, never passwords) — the "I signed
    // out and now I'm retyping everything" fix. Loaded once per screen (iOS
    // onAppear).
    val history = remember { LoginHistory.all() }
    val scope = rememberCoroutineScope()

    val canSubmit = !busy && username.isNotEmpty() && password.isNotEmpty() && serverOrigin.trim().isNotEmpty()
    val suggestions = loginSuggestions(history, serverOrigin, username)

    fun doLogin() {
        error = null
        busy = true
        // Point the global origin at the target server for the login call, but
        // restore it on failure — an "Add account" attempt must not hijack the
        // still-active environment when the password was wrong.
        val previousOrigin = Config.serverOrigin
        Config.serverOrigin = serverOrigin
        scope.launch {
            try {
                AppState.login(username, password)
                onSuccess?.invoke()
            } catch (e: Exception) {
                Config.serverOrigin = previousOrigin
                error = e.message ?: "Sign-in failed."
            }
            busy = false
        }
    }

    /** An access payload (in-app scan or camera deep link): fill the fields,
     * and when it carries the full credentials, sign straight in — that's
     * the hand-off. */
    fun applyAccess(p: AccessPayload) {
        serverOrigin = Config.normalize(p.origin)
        p.username?.let { username = it }
        p.password?.let { password = it }
        if (username.isNotEmpty() && password.isNotEmpty()) doLogin()
    }

    // Take the waiting access link. Keyed on the value, so it covers both the
    // already-on-screen case (root login when signed out — the link arrives
    // after first composition; iOS onChange) and a screen raised for it
    // (iOS onAppear).
    val pendingAccess by AppState.pendingAccess.collectAsStateWithLifecycle()
    LaunchedEffect(pendingAccess) {
        val p = pendingAccess ?: return@LaunchedEffect
        AppState.pendingAccess.value = null
        applyAccess(p)
    }

    Box(Modifier.fillMaxSize().background(MyMuColors.background)) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .imePadding()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(60.dp))
        Text("MyMu", color = MyMuColors.primary, fontSize = 44.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text("Drive your agents", color = MyMuColors.mutedText, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(22.dp))

        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.weight(1f)) {
                LoginField("Server", serverOrigin, { serverOrigin = it }, Icons.Outlined.Dns, KeyboardType.Uri)
            }
            // Camera hand-off: scan an access QR from another MyMu and land
            // signed in (or at least pre-filled). 56dp = the M3 field height.
            Box(
                Modifier
                    .size(56.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MyMuColors.surface)
                    .border(1.dp, MyMuColors.border, RoundedCornerShape(12.dp))
                    .clickable { showScanner = true },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.QrCodeScanner, contentDescription = "Scan access QR",
                    tint = MyMuColors.primary, modifier = Modifier.size(22.dp))
            }
        }
        if (suggestions.isNotEmpty()) {
            Spacer(Modifier.height(12.dp))
            HistoryChips(suggestions) { m ->
                serverOrigin = m.origin
                username = m.username
            }
        }
        Spacer(Modifier.height(12.dp))
        LoginField("Username", username, { username = it }, Icons.Outlined.Person)
        Spacer(Modifier.height(12.dp))
        LoginField("Password", password, { password = it }, Icons.Outlined.Lock, KeyboardType.Password, secure = true)

        if (notice != null) {
            Spacer(Modifier.height(12.dp))
            Text(notice, color = MyMuColors.primary, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth())
        }
        Spacer(Modifier.height(12.dp))
        Text(
            "Point MyMu at your own Claude Code UI server.",
            color = MyMuColors.mutedText, style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.fillMaxWidth(),
        )
        if (error != null) {
            Spacer(Modifier.height(12.dp))
            Text(error ?: "", color = MyMuColors.danger, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth())
        }
        Spacer(Modifier.height(22.dp))

        Button(
            onClick = { doLogin() },
            enabled = canSubmit,
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = MyMuColors.primary,
                contentColor = MyMuColors.background,
                disabledContainerColor = MyMuColors.primary.copy(alpha = 0.5f),
                disabledContentColor = MyMuColors.background,
            ),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                if (busy) {
                    CircularProgressIndicator(
                        modifier = Modifier.width(18.dp).height(18.dp),
                        color = MyMuColors.background, strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                }
                Text(if (busy) "Signing in…" else "Sign in", fontWeight = FontWeight.SemiBold)
            }
        }

        if (onSuccess == null) {
            Spacer(Modifier.height(12.dp))
            // Explore with no server at all — canned DemoData, same as iOS.
            Button(
                onClick = { AppState.enterDemo() },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth().height(50.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MyMuColors.background,
                    contentColor = MyMuColors.primary,
                ),
                border = androidx.compose.foundation.BorderStroke(1.dp, MyMuColors.border),
            ) {
                Text("Try the demo", fontWeight = FontWeight.Medium)
            }
        }
        Spacer(Modifier.height(40.dp))
    }
    // Pinned re-login must never be a trap: a REAL back button (not a footnote
    // link nobody finds) returns to the accounts that still work.
    if (onCancel != null) {
        TextButton(
            onClick = onCancel,
            modifier = Modifier
                .align(Alignment.TopStart)
                .statusBarsPadding()
                .padding(start = 4.dp, top = 4.dp),
        ) {
            Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back",
                tint = MyMuColors.primary, modifier = Modifier.height(18.dp))
            Spacer(Modifier.width(4.dp))
            Text("Back", color = MyMuColors.primary)
        }
    }
    }

    if (showScanner) {
        QRScanSheet(onScan = { applyAccess(it) }, onDismiss = { showScanner = false })
    }
}

/**
 * Matching hosts from past logins, shown as one-tap chips. Filtered by what's
 * typed so far; everything when the field is empty. Hidden once the field
 * exactly holds a remembered origin (job done). (iOS LoginView.suggestions.)
 */
private fun loginSuggestions(history: List<LoginMemory>, serverOrigin: String, username: String): List<LoginMemory> {
    val typed = serverOrigin.trim().lowercase()
    if (typed.isEmpty()) return history.take(4)
    val matches = history.filter {
        it.hostLabel.lowercase().contains(typed) || it.origin.lowercase().contains(typed)
    }
    val only = matches.singleOrNull()
    if (only != null && only.origin.lowercase() == Config.normalize(typed).lowercase() &&
        only.username == username) return emptyList()
    return matches.take(4)
}

/** One row of "user · host" capsules (iOS historyChips); a tap fills both fields. */
@Composable
private fun HistoryChips(suggestions: List<LoginMemory>, onPick: (LoginMemory) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (m in suggestions) {
            Row(
                Modifier
                    .clip(CircleShape)
                    .background(MyMuColors.surface)
                    .border(1.dp, MyMuColors.border, CircleShape)
                    .clickable { onPick(m) }
                    .padding(horizontal = 11.dp, vertical = 7.dp),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.History, contentDescription = null,
                    tint = MyMuColors.primary, modifier = Modifier.size(13.dp))
                Text("${m.username} · ${m.hostLabel}", color = MyMuColors.text,
                    style = MaterialTheme.typography.labelMedium, maxLines = 1)
            }
        }
    }
}

/** The login screen's field style — shared with AccessQRSheet's password
 * field, which iOS styles identically inline. */
@Composable
internal fun LoginField(
    placeholder: String,
    value: String,
    onValue: (String) -> Unit,
    icon: ImageVector,
    keyboardType: KeyboardType = KeyboardType.Text,
    secure: Boolean = false,
) {
    TextField(
        value = value,
        onValueChange = onValue,
        singleLine = true,
        placeholder = { Text(placeholder, color = MyMuColors.mutedText, maxLines = 1) },
        leadingIcon = { Icon(icon, contentDescription = placeholder, tint = MyMuColors.mutedText) },
        visualTransformation = if (secure) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, autoCorrectEnabled = false),
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, MyMuColors.border, RoundedCornerShape(12.dp)),
        shape = RoundedCornerShape(12.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MyMuColors.surface,
            unfocusedContainerColor = MyMuColors.surface,
            focusedTextColor = MyMuColors.text,
            unfocusedTextColor = MyMuColors.text,
            cursorColor = MyMuColors.primary,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
        ),
    )
}
