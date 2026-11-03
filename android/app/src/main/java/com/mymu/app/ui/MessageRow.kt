package com.mymu.app.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mymu.app.core.ChatMessage
import com.mymu.app.core.Haptics
import com.mymu.app.core.MessageTime
import org.json.JSONArray
import org.json.JSONObject

/**
 * Renders one normalized chat message, Claude/ChatGPT-app style (port of iOS
 * MessageRow): assistant text is full-width with real markdown; user text is a
 * right-aligned bubble; tools/thinking render muted; SendUserFile deliveries
 * render inline media.
 *
 * Text messages get NO row-level long-press menu: long-press there belongs to
 * the in-message text selection (SelectionContainer); every other kind keeps
 * long-press → Copy, exactly like iOS MessageRow's contextMenu split.
 */
@Composable
fun MessageRow(m: ChatMessage, projectId: String, token: String, origin: String?,
               showActions: Boolean = false) {
    if (m.kind == "text") {
        TextBody(m, showActions)
        return
    }
    val body = m.bodyText.trim()
    LongPressCopy(copyText = body.ifEmpty { m.content ?: "" }) {
        when (m.kind) {
            "tool_use" -> {
                val delivered = deliveredFiles(m)
                if (delivered != null) MediaDelivery(delivered.first, delivered.second, projectId, token, origin)
                else ToolUseChip(m)
            }
            "tool_result" -> ToolResultRow(m)
            "thinking" -> ThinkingRow(m)
            "error" -> ErrorRow(m)
            else -> {}
        }
    }
}

/**
 * Long-press → Copy for tool/thinking/error rows (iOS contextMenu parity).
 * The selectable text INSIDE these rows wins the long-press when the finger is
 * on the text itself (selection starts); the row's blank space and icons open
 * this menu — same effective split as iOS.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun LongPressCopy(copyText: String, content: @Composable () -> Unit) {
    if (copyText.isEmpty()) { content(); return }
    var menu by remember { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    Box {
        Box(
            Modifier.combinedClickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = {},
                onLongClick = { Haptics.attention(); menu = true },
            ),
        ) { content() }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Copy") },
                leadingIcon = {
                    Icon(Icons.Outlined.ContentCopy, contentDescription = null,
                        tint = MyMuColors.mutedText, modifier = Modifier.size(16.dp))
                },
                onClick = {
                    clipboard.setText(AnnotatedString(copyText))
                    menu = false
                },
            )
        }
    }
}

// MARK: text ---------------------------------------------------------------

@Composable
private fun TextBody(m: ChatMessage, showActions: Boolean) {
    val body = m.bodyText.trim()
    when {
        m.isInjected == true -> InjectedContextChip(body)
        m.role == "user" -> {
            // ChatGPT geometry (wave 6, iOS MessageRow parity): right-aligned
            // soft bubble, ~80% of the column at most (300dp cap), 16/10
            // padding, 22dp corners, at least 48dp of air on the leading side
            // (iOS `Spacer(minLength: 48)`). No timestamp — the row carries the
            // message and nothing else (the stamps on every row were part of
            // what read as "heavy"; Manar 2026-10-23). The extra 6dp on top is
            // turn separation: a user message opens a turn.
            Column(
                Modifier.fillMaxWidth().padding(start = 16.dp + 48.dp, end = 16.dp, top = 6.dp),
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                m.images?.forEach { url ->
                    DataUrlImage(url, zoomable = true,
                        modifier = Modifier
                            .widthIn(max = 260.dp)
                            .heightIn(max = 260.dp))
                }
                if (body.isNotEmpty()) {
                    Box(
                        Modifier
                            .widthIn(max = 300.dp)
                            .background(MyMuColors.userBubble, RoundedCornerShape(MyMuRadius.bubble))
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                    ) {
                        MarkdownView(body)
                    }
                }
                // Sent mid-turn: sitting in the agent's queue until the run ends.
                if (m.queued == true) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Schedule, contentDescription = null,
                            tint = MyMuColors.mutedText, modifier = Modifier.size(10.dp))
                        Spacer(Modifier.width(3.dp))
                        Text("Queued", color = MyMuColors.mutedText, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
        else -> {
            // Assistant rows are unboxed: full-width markdown, nothing else.
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                MarkdownView(body, modifier = Modifier.fillMaxWidth())
                if (showActions) CopyButton(if (body.isEmpty()) (m.content ?: "") else body)
            }
        }
    }
}

/** When the message was sent — same wording as the web client. No longer
 * rendered inline on transcript rows (wave 6); kept for callers that still
 * want a stamp (previews, exports). */
@Composable
fun TimeStampLabel(timestamp: String?) {
    val label = remember(timestamp) { MessageTime.label(timestamp) } ?: return
    Text(label, color = MyMuColors.mutedText.copy(alpha = 0.8f),
        style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 2.dp))
}

/** Visible copy affordance under the newest assistant message. */
@Composable
fun CopyButton(text: String) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable { clipboard.setText(AnnotatedString(text)); copied = true },
    ) {
        Icon(if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
            contentDescription = "Copy", tint = MyMuColors.mutedText, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(4.dp))
        Text(if (copied) "Copied" else "Copy", color = MyMuColors.mutedText,
            style = MaterialTheme.typography.labelSmall)
    }
}

// MARK: tools --------------------------------------------------------------

private fun toolIcon(tool: String?): ImageVector = when (tool ?: "") {
    "Read" -> Icons.Outlined.Description
    "Write", "Edit", "MultiEdit" -> Icons.Outlined.Edit
    "Bash" -> Icons.Outlined.Terminal
    "Grep", "Glob" -> Icons.Outlined.Search
    "WebFetch", "WebSearch" -> Icons.Outlined.Public
    "Task" -> Icons.Outlined.Group
    "TodoWrite" -> Icons.Outlined.Checklist
    "SendUserFile" -> Icons.Outlined.AttachFile
    else -> Icons.Outlined.Build
}

@Composable
private fun ToolUseChip(m: ChatMessage) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .border(1.dp, MyMuColors.border, CircleShape)
                .background(MyMuColors.surface, CircleShape)
                .padding(horizontal = 10.dp, vertical = 5.dp),
        ) {
            Icon(toolIcon(m.toolName), contentDescription = null,
                tint = MyMuColors.mutedText, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(6.dp))
            Text(m.toolName ?: "tool", color = MyMuColors.mutedText,
                style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun ToolResultRow(m: ChatMessage) {
    val c = m.content ?: return
    if (c.isEmpty()) return
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp)) {
        Icon(Icons.Outlined.ChevronRight, contentDescription = null,
            tint = MyMuColors.mutedText.copy(alpha = 0.7f), modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(8.dp))
        // Cap what reaches layout — a runaway tool result froze the chat.
        // Selectable: partial-range copy, same surface iOS marks
        // .textSelection(.enabled) (MessageRow.swift:166).
        SelectionContainer {
            Text(
                if (c.length > 4000) c.take(4000) + "…" else c,
                color = if (m.isError == true) MyMuColors.danger else MyMuColors.mutedText,
                fontFamily = FontFamily.Monospace,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 10, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Reasoning output, muted and italic — for a reasoning model this is most of
 * a turn's wall-clock; hiding it reads as the app being frozen. */
@Composable
private fun ThinkingRow(m: ChatMessage) {
    val c = m.content ?: return
    if (c.isBlank()) return
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp)) {
        Icon(Icons.Outlined.AutoAwesome, contentDescription = null,
            tint = MyMuColors.mutedText.copy(alpha = 0.7f), modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(8.dp))
        SelectionContainer {
            Text(
                if (c.length > 4000) c.take(4000) + "…" else c,
                color = MyMuColors.mutedText.copy(alpha = 0.85f),
                fontStyle = FontStyle.Italic,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 8, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun ErrorRow(m: ChatMessage) {
    Text(
        m.content ?: "Error",
        color = MyMuColors.danger,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .background(MyMuColors.danger.copy(alpha = 0.12f), RoundedCornerShape(MyMuRadius.chip))
            .padding(10.dp),
    )
}

// MARK: delivered media (SendUserFile) --------------------------------------

private fun deliveredFiles(m: ChatMessage): Pair<List<String>, String?>? {
    if (m.kind != "tool_use" || m.toolName != "SendUserFile") return null
    val dict = m.toolInput as? JSONObject ?: return null
    val arr = dict.opt("files") as? JSONArray ?: return null
    val files = (0 until arr.length()).mapNotNull { arr.opt(it) as? String }
    if (files.isEmpty()) return null
    return files to (dict.opt("caption") as? String)
}

@Composable
private fun MediaDelivery(files: List<String>, caption: String?, projectId: String,
                          token: String, origin: String?) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!caption.isNullOrEmpty()) {
            Text(caption, color = MyMuColors.mutedText, style = MaterialTheme.typography.bodySmall)
        }
        for (f in files) DeliveredMediaView(f, projectId, token, origin)
    }
}

// MARK: injected context chip -----------------------------------------------

/** First markdown heading if there is one, else the first line, clipped. */
fun injectedLabel(body: String): String {
    val heading = body.split("\n").firstOrNull { it.startsWith("#") }
        ?.trimStart('#', ' ')
    val source = heading ?: body.trimStart().substringBefore("\n")
    val trimmed = source.trim()
    if (trimmed.isEmpty()) return "Injected instructions"
    return if (trimmed.length > 56) trimmed.take(56).trim() + "…" else trimmed
}

/** Collapsed "Context added automatically" chip for harness-injected content. */
@Composable
private fun InjectedContextChip(body: String) {
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).animateContentSize()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .border(1.dp, MyMuColors.border, CircleShape)
                .background(MyMuColors.surface, CircleShape)
                .clickable { expanded = !expanded }
                .padding(horizontal = 10.dp, vertical = 5.dp),
        ) {
            Icon(if (expanded) Icons.Outlined.KeyboardArrowDown else Icons.Outlined.KeyboardArrowRight,
                contentDescription = null, tint = MyMuColors.mutedText, modifier = Modifier.size(13.dp))
            Icon(Icons.Outlined.Settings, contentDescription = null,
                tint = MyMuColors.mutedText, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(5.dp))
            Text("Context · ${injectedLabel(body)}", color = MyMuColors.mutedText,
                style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (expanded) {
            SelectionContainer {
                Text(
                    body, color = MyMuColors.mutedText, fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .padding(top = 6.dp)
                        .heightIn(max = 260.dp)
                        .verticalScroll(rememberScrollState())
                        .fillMaxWidth()
                        .background(MyMuColors.surface, RoundedCornerShape(MyMuRadius.chip))
                        .border(1.dp, MyMuColors.border, RoundedCornerShape(MyMuRadius.chip))
                        .padding(10.dp),
                )
            }
        }
    }
}

// MARK: tool group ----------------------------------------------------------

/**
 * A collapsed run of consecutive tool activity: "▸ 7 steps · Bash, Read, Edit".
 * Tapping expands to the full rows in place. (Port of iOS ToolGroupRow.)
 */
@Composable
fun ToolGroupRow(members: List<ChatMessage>, expanded: Boolean, toggle: () -> Unit,
                 projectId: String, token: String, origin: String?) {
    // Unique tool names in first-use order; thinking reads as "thinking".
    val summary = remember(members) {
        val seen = mutableListOf<String>()
        for (m in members) {
            if (m.kind == "tool_result") continue
            val name = if (m.kind == "thinking") "thinking" else (m.toolName ?: "tool")
            if (name !in seen) seen.add(name)
        }
        val names = seen.take(4).joinToString(", ")
        if (seen.size > 4) "$names…" else names
    }

    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .padding(horizontal = 16.dp)
                .fillMaxWidth()
                .border(1.dp, MyMuColors.border, RoundedCornerShape(12.dp))
                .background(MyMuColors.surface, RoundedCornerShape(12.dp))
                .clickable(onClick = toggle)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                contentDescription = null, tint = MyMuColors.mutedText, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(7.dp))
            Icon(Icons.Outlined.Build, contentDescription = null,
                tint = MyMuColors.primary, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(7.dp))
            Text("${members.size} steps", color = MyMuColors.text,
                style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
            Spacer(Modifier.width(7.dp))
            Text(summary, color = MyMuColors.mutedText, style = MaterialTheme.typography.bodySmall,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (expanded) {
            Column(
                Modifier.padding(start = 10.dp, top = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                for (m in members) MessageRow(m, projectId, token, origin)
            }
        }
    }
}
