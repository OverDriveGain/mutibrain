package com.mymu.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mymu.app.core.ApiClient
import com.mymu.app.core.ApiException

/**
 * Pick a slash command and drop it into the composer. (Port of iOS
 * SlashCommandSheet — a searchable sheet, because the user-level command set
 * on a fleet machine holds dozens of entries.) Selecting INSERTS `/name ` —
 * the agent interprets its own slash commands, and insertion leaves room for
 * arguments before sending.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SlashCommandSheet(
    api: ApiClient,
    projectPath: String?,
    onPick: (ApiClient.SlashCommand) -> Unit,
    onDismiss: () -> Unit,
) {
    var commands by remember { mutableStateOf<List<ApiClient.SlashCommand>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        try {
            commands = api.slashCommands(projectPath)
        } catch (e: ApiException) {
            // A 5xx is the server's fault and nothing the user can act on.
            error = if (e.code >= 500)
                "${e.host ?: "The server"} couldn't list its commands (HTTP ${e.code}). " +
                    "This is a server-side fault, not something to fix on the phone."
            else e.message
        } catch (e: Exception) {
            error = e.message
        }
        loading = false
    }

    val filtered = remember(commands, query) {
        val q = query.trim()
        if (q.isEmpty()) commands
        else commands.filter {
            it.name.contains(q, ignoreCase = true) ||
                (it.description ?: "").contains(q, ignoreCase = true)
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MyMuColors.surface) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Text("Commands", color = MyMuColors.text, style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
            TextField(
                value = query, onValueChange = { query = it }, singleLine = true,
                placeholder = { Text("Search commands", color = MyMuColors.mutedText) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MyMuColors.elevated,
                    unfocusedContainerColor = MyMuColors.elevated,
                    focusedTextColor = MyMuColors.text,
                    unfocusedTextColor = MyMuColors.text,
                    cursorColor = MyMuColors.primary,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
            )
            when {
                loading -> MyMuLoader(modifier = Modifier.padding(16.dp))
                error != null -> Text(error ?: "", color = MyMuColors.danger,
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(16.dp))
                commands.isEmpty() -> Text("No commands on this server.",
                    color = MyMuColors.mutedText, modifier = Modifier.padding(16.dp))
                filtered.isEmpty() -> Text("No command matches \"$query\".",
                    color = MyMuColors.mutedText, modifier = Modifier.padding(16.dp))
                else -> LazyColumn(Modifier.heightIn(max = 460.dp)) {
                    items(filtered, key = { it.id }) { cmd ->
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clickable { onPick(cmd) }
                                .padding(horizontal = 16.dp, vertical = 8.dp),
                        ) {
                            Row {
                                Text(cmd.invocation, color = MyMuColors.primary,
                                    fontFamily = FontFamily.Monospace,
                                    style = MaterialTheme.typography.bodyMedium, maxLines = 1)
                                val ns = cmd.namespace
                                if (!ns.isNullOrEmpty() && ns != "user") {
                                    Spacer(Modifier.width(6.dp))
                                    Text(ns, color = MyMuColors.mutedText,
                                        style = MaterialTheme.typography.labelSmall,
                                        modifier = Modifier
                                            .background(MyMuColors.elevated, CircleShape)
                                            .padding(horizontal = 6.dp, vertical = 2.dp))
                                }
                            }
                            val d = cmd.description
                            if (!d.isNullOrEmpty()) {
                                Text(d, color = MyMuColors.mutedText,
                                    style = MaterialTheme.typography.labelMedium,
                                    maxLines = 2, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
        }
    }
}
