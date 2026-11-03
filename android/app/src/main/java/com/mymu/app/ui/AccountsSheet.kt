package com.mymu.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Logout
import androidx.compose.material.icons.outlined.QrCode
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mymu.app.core.AppState
import com.mymu.app.core.Config
import com.mymu.app.core.SavedAccount
import org.json.JSONObject

/**
 * Account switcher — Gmail-style multiple logins (port of iOS AccountsSheet).
 * Tap a row to switch; the trash affordance signs out (confirmed first —
 * destructive and unrecoverable without the password). Also hosts the
 * MCP-servers entry and the app/server version lines.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountsSheet(
    onAddAccount: () -> Unit,
    onOpenMcp: () -> Unit,
    onDismiss: () -> Unit,
) {
    val accounts by AppState.accounts.collectAsStateWithLifecycle()
    val activeId by AppState.activeAccountId.collectAsStateWithLifecycle()
    var pendingSignOut by remember { mutableStateOf<SavedAccount?>(null) }
    var serverVersion by remember { mutableStateOf<String?>(null) }
    var showAccessQR by remember { mutableStateOf(false) }
    val active = accounts.firstOrNull { it.id == activeId }

    // Active host's backend build (/api/version, unauthenticated, best-effort).
    LaunchedEffect(Unit) {
        serverVersion = try {
            val body = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                com.mymu.app.core.ApiClient.http.newCall(
                    okhttp3.Request.Builder().url(Config.serverOrigin + "/api/version").build()
                ).execute().use { it.body?.string() }
            } ?: return@LaunchedEffect
            val o = JSONObject(body)
            val parts = mutableListOf<String>()
            o.optString("version").takeIf { it.isNotEmpty() }?.let { parts.add("v$it") }
            // "built 13 Sep 12:39" — the server's build timestamp, local time
            // (iOS Components.swift renders builtAt the same way).
            o.optString("builtAt").takeIf { it.isNotEmpty() }?.let { iso ->
                try {
                    val instant = java.time.OffsetDateTime.parse(iso).toInstant()
                    val local = instant.atZone(java.time.ZoneId.systemDefault())
                    val fmt = java.time.format.DateTimeFormatter.ofPattern(
                        "dd MMM HH:mm", java.util.Locale.ENGLISH)
                    parts.add("built " + local.format(fmt))
                } catch (_: Exception) {}
            }
            if (parts.isEmpty()) null else parts.joinToString(" · ")
        } catch (_: Exception) { null }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MyMuColors.surface) {
        Column(Modifier.fillMaxWidth().padding(bottom = 28.dp)) {
            Text("Accounts", color = MyMuColors.text, style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))

            for (acct in accounts) {
                val isActive = acct.id == activeId
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            if (!isActive) AppState.switchTo(acct)
                            onDismiss()
                        }
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Monogram — the conventional stand-in for an avatar.
                    androidx.compose.foundation.layout.Box(
                        Modifier
                            .size(34.dp)
                            .background(
                                if (isActive) MyMuColors.primary else MyMuColors.primary.copy(alpha = 0.15f),
                                CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            acct.username.firstOrNull()?.uppercase() ?: "?",
                            color = if (isActive) MyMuColors.background else MyMuColors.primary,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(acct.username, color = MyMuColors.text,
                            fontWeight = if (isActive) FontWeight.SemiBold else FontWeight.Normal,
                            maxLines = 1)
                        Text(acct.hostLabel, color = MyMuColors.mutedText,
                            style = MaterialTheme.typography.labelMedium,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    if (isActive) {
                        Icon(Icons.Outlined.Check, contentDescription = "Active",
                            tint = MyMuColors.primary, modifier = Modifier.size(16.dp))
                    }
                    IconButton(onClick = { pendingSignOut = acct }) {
                        Icon(Icons.Outlined.Logout, contentDescription = "Sign out",
                            tint = MyMuColors.mutedText, modifier = Modifier.size(16.dp))
                    }
                }
            }

            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { onDismiss(); onAddAccount() }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Add, contentDescription = null,
                    tint = MyMuColors.primary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(12.dp))
                Text("Add account", color = MyMuColors.text)
            }

            // Hand this login to another device: show a QR the other MyMu
            // scans on its login screen (server + user; password only if
            // typed into the sheet). Active account only, as on iOS.
            if (active != null) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { showAccessQR = true }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.QrCode, contentDescription = null,
                        tint = MyMuColors.primary, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(12.dp))
                    Text("Share access QR", color = MyMuColors.text)
                }
            }

            // Host-level configuration lives with the account it belongs to.
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { onDismiss(); onOpenMcp() }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Extension, contentDescription = null,
                    tint = MyMuColors.primary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(12.dp))
                Text("MCP servers", color = MyMuColors.text)
            }

            Text(
                listOfNotNull("App v" + com.manarz.myagent.BuildConfig.VERSION_NAME,
                    serverVersion?.let { "Server $it" }).joinToString("   ·   "),
                color = MyMuColors.mutedText, style = MaterialTheme.typography.labelSmall,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }

    // Stacked on the accounts sheet, as iOS stacks its .sheet — Done/swipe
    // returns here, not to the list behind.
    if (showAccessQR && active != null) {
        AccessQRSheet(
            origin = Config.normalize(active.serverOrigin),
            username = active.username,
            onDismiss = { showAccessQR = false },
        )
    }

    val out = pendingSignOut
    if (out != null) {
        AlertDialog(
            onDismissRequest = { pendingSignOut = null },
            title = { Text("Sign out ${out.username} · ${out.hostLabel}?") },
            confirmButton = {
                TextButton(onClick = {
                    AppState.removeAccount(out)
                    pendingSignOut = null
                    onDismiss()
                }) { Text("Sign out", color = MyMuColors.danger) }
            },
            dismissButton = { TextButton(onClick = { pendingSignOut = null }) { Text("Cancel") } },
            containerColor = MyMuColors.surface,
            titleContentColor = MyMuColors.text,
        )
    }
}
