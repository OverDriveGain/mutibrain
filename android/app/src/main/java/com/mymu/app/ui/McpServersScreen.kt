package com.mymu.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mymu.app.core.ApiClient
import com.mymu.app.core.AppState
import kotlinx.coroutines.launch

/**
 * The MCP servers configured on the active host, grouped by scope.
 * READ + REMOVE only (composing a server belongs on a keyboard, and a typo
 * produces a broken server rather than an obvious error). Port of iOS
 * McpServersView.
 */
@Composable
fun McpServersScreen(onBack: () -> Unit) {
    val api = remember { AppState.api }
    var servers by remember { mutableStateOf<List<ApiClient.McpServer>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var pendingDelete by remember { mutableStateOf<ApiClient.McpServer?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        error = null
        try { servers = api.mcpServers() } catch (e: Exception) { error = e.message }
        loading = false
    }
    LaunchedEffect(reload) { load() }

    Column(Modifier.fillMaxSize()) {
        MyMuTopBar("MCP servers", onBack = onBack)
        when {
            loading && servers.isEmpty() -> LoadingBox()
            error != null -> CenteredNote(error ?: "", danger = true)
            servers.isEmpty() -> CenteredNote("No MCP servers configured on this host.")
            else -> {
                // user / local / project first — user scope is the machine-wide set.
                val order = listOf("user", "local", "project", "other")
                val grouped = servers.groupBy { it.scope ?: "other" }
                RefreshableList(refreshing, onRefresh = {
                    scope.launch { refreshing = true; load(); refreshing = false }
                }) { LazyColumn {
                    for (scopeName in order.filter { grouped.containsKey(it) }) {
                        item(key = "hdr-$scopeName") {
                            Text(scopeName.uppercase(), color = MyMuColors.mutedText,
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier.padding(start = 16.dp, top = 14.dp, bottom = 4.dp))
                        }
                        items(grouped[scopeName] ?: emptyList(), key = { it.id }) { s ->
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(
                                    if (s.transport == "stdio") Icons.Outlined.Terminal else Icons.Outlined.Lan,
                                    contentDescription = null, tint = MyMuColors.primary,
                                    modifier = Modifier.size(20.dp),
                                )
                                Spacer(Modifier.width(12.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(s.name, color = MyMuColors.text,
                                        style = MaterialTheme.typography.bodyLarge, maxLines = 1)
                                    Text(s.target, color = MyMuColors.mutedText,
                                        fontFamily = FontFamily.Monospace,
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                s.transport?.let { t ->
                                    Text(t, color = MyMuColors.mutedText,
                                        style = MaterialTheme.typography.labelSmall,
                                        modifier = Modifier
                                            .padding(end = 4.dp)
                                            .clickable { }
                                            .padding(horizontal = 6.dp, vertical = 2.dp))
                                }
                                IconButton(onClick = { pendingDelete = s }) {
                                    Icon(Icons.Outlined.Delete, contentDescription = "Remove",
                                        tint = MyMuColors.danger, modifier = Modifier.size(18.dp))
                                }
                            }
                        }
                    }
                } }
            }
        }
    }

    val del = pendingDelete
    if (del != null) {
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Remove \"${del.name}\"?") },
            text = { Text("The agent will lose this server's tools on its next run.") },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    scope.launch {
                        try {
                            api.deleteMcpServer(name = del.name, scope = del.scope)
                            reload += 1
                        } catch (e: Exception) { error = e.message }
                    }
                }) { Text("Remove", color = MyMuColors.danger) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
            containerColor = MyMuColors.surface,
            titleContentColor = MyMuColors.text,
            textContentColor = MyMuColors.mutedText,
        )
    }
}
