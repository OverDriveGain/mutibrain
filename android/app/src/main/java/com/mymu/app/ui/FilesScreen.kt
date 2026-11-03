package com.mymu.app.ui

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.automirrored.outlined.NoteAdd
import androidx.compose.material.icons.outlined.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.TextButton
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import com.mymu.app.core.Haptics
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Audiotrack
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DataObject
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.IosShare
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import android.widget.Toast
import kotlinx.coroutines.launch
import com.mymu.app.core.ApiClient
import com.mymu.app.core.ApiException
import com.mymu.app.core.AppState
import com.mymu.app.core.Config
import com.mymu.app.core.FileNode
import androidx.lifecycle.compose.collectAsStateWithLifecycle

private fun fileIcon(name: String): ImageVector = when (name.substringAfterLast('.', "").lowercase()) {
    "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "c", "cpp", "h", "kt" -> Icons.Outlined.Code
    "json", "yml", "yaml", "toml" -> Icons.Outlined.DataObject
    "md", "txt", "rtf" -> Icons.Outlined.Description
    "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp" -> Icons.Outlined.Image
    "mp4", "mov", "m4v" -> Icons.Outlined.Movie
    "mp3", "wav", "m4a", "aac", "flac" -> Icons.Outlined.Audiotrack
    "pdf" -> Icons.Outlined.PictureAsPdf
    "sh", "bash", "zsh" -> Icons.Outlined.Terminal
    else -> Icons.AutoMirrored.Outlined.InsertDriveFile
}

/**
 * Last fetched listing per (host, project, folder). Only the top route is
 * composed (MainTabs), so a level's own refetch would die with it on pop — and
 * re-entering a folder would show the snapshot its parent was pushed with,
 * i.e. without the upload just made inside it. iOS keeps the parent level
 * alive in its NavigationStack; this cache is the Android equivalent.
 */
private object FileLevelCache {
    private val levels = mutableMapOf<String, List<FileNode>>()
    fun key(origin: String?, projectId: String, folderPath: String) = "${origin ?: ""}|$projectId|$folderPath"
    operator fun get(key: String): List<FileNode>? = synchronized(levels) { levels[key] }
    operator fun set(key: String, value: List<FileNode>) = synchronized(levels) { levels[key] = value }
}

private enum class CreateKind { FILE, FOLDER }

/**
 * One level of the agent/project file tree (port of iOS FilesView/FileBrowser):
 * two levels load per call, deeper folders fetch on demand; files open a
 * preview. For a cross-host relay agent the server has no filesystem channel,
 * so a friendly note shows instead of an error.
 *
 * File management (iOS ff6adcf, Manar 2026-09-29: "download shouldn't need
 * opening the file first"): long-press a row for Download (bytes → share
 * sheet, no preview), Rename, Copy path, Delete (confirm; folders warn
 * recursive); the top-bar "+" uploads into / creates inside THIS folder;
 * pull-to-refresh on every level.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun FilesScreen(route: Route.Files, onOpen: (Route) -> Unit, onBack: () -> Unit) {
    val token = route.tokenOverride ?: AppState.token.collectAsStateWithLifecycle().value ?: return
    val api = remember(route) { ApiClient(token, route.origin) }
    // This level's own tree path ("" = root) — where uploads/creates land and
    // what a post-mutation refresh refetches.
    val folderPath = route.path ?: ""
    val cacheKey = FileLevelCache.key(route.origin, route.projectId, folderPath)
    var fetched by remember { mutableStateOf(FileLevelCache[cacheKey]) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    // A refetch (post-mutation / pull-to-refresh) overrides the snapshot this
    // level was pushed with.
    val nodes = fetched ?: route.preloaded
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    // File management state.
    var refreshing by remember { mutableStateOf(false) }
    var addMenu by remember { mutableStateOf(false) }
    var uploading by remember { mutableStateOf(false) }
    var creating by remember { mutableStateOf<CreateKind?>(null) }
    var createName by remember { mutableStateOf("") }
    var menuFor by remember { mutableStateOf<FileNode?>(null) }
    var renaming by remember { mutableStateOf<FileNode?>(null) }
    var renameText by remember { mutableStateOf("") }
    var deleting by remember { mutableStateOf<FileNode?>(null) }
    var downloadingPath by remember { mutableStateOf<String?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }

    /** Refetches THIS level. `showErrorInline` renders the failure as the
     * empty state (initial load); `quiet` swallows it (background revalidate
     * over a cached listing); otherwise it pops the action alert. */
    suspend fun refresh(showErrorInline: Boolean = false, quiet: Boolean = false) {
        try {
            val tree = api.files(route.projectId, folderPath.ifEmpty { null }, depth = 2).sortedWith(
                compareByDescending<FileNode> { it.isDir }.thenBy { it.name.lowercase() })
            fetched = tree
            FileLevelCache[cacheKey] = tree
            error = null
        } catch (e: ApiException) {
            if (quiet) return
            if (!showErrorInline) actionError = "Couldn't refresh this folder."
            else error = if (e.code == 404 || e.code == 502)
                "Files aren't available for this agent — it may be running on another host."
            else e.message
        } catch (e: Exception) {
            if (quiet) return
            if (showErrorInline) error = e.message else actionError = "Couldn't refresh this folder."
        }
    }

    // Fetch-on-open levels (root, folders the walk didn't reach) always load;
    // a cached listing paints first and is revalidated quietly.
    LaunchedEffect(route) {
        if (route.preloaded != null) return@LaunchedEffect
        if (fetched == null) refresh(showErrorInline = true) else refresh(quiet = true)
    }

    // Multi-file SAF picker → bytes under each document's display name.
    val uploadPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            uploading = true
            val unreadable = mutableListOf<String>()
            val files = withContext(Dispatchers.IO) {
                uris.mapIndexedNotNull { i, uri ->
                    val name = displayName(context, uri) ?: "upload-${i + 1}"
                    try {
                        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        if (bytes == null) { unreadable += name; null }
                        else ApiClient.Attachment(name,
                            context.contentResolver.getType(uri) ?: "application/octet-stream", bytes)
                    } catch (_: Exception) { unreadable += name; null }
                }
            }
            try {
                api.uploadProjectFiles(route.projectId, folderPath, files)
                refresh()
                if (unreadable.isNotEmpty()) actionError = "Couldn't read: ${unreadable.joinToString(", ")}."
            } catch (e: Exception) {
                actionError = "Upload failed. ${e.message ?: ""}".trim()
            }
            uploading = false
        }
    }

    fun mutate(failure: String, op: suspend () -> Unit) {
        scope.launch {
            try { op(); refresh() }
            catch (e: Exception) { actionError = "$failure ${e.message ?: ""}".trim() }
        }
    }

    Column(Modifier.fillMaxSize()) {
        MyMuTopBar(route.title, onBack = onBack, actions = {
            if (uploading) {
                CircularProgressIndicator(Modifier.padding(horizontal = 12.dp).size(18.dp),
                    color = MyMuColors.primary, strokeWidth = 2.dp)
            } else Box {
                IconButton(onClick = { addMenu = true }) {
                    Icon(Icons.Outlined.Add, contentDescription = "Add to this folder",
                        tint = MyMuColors.primary)
                }
                DropdownMenu(expanded = addMenu, onDismissRequest = { addMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("Upload files") },
                        leadingIcon = { MenuIcon(Icons.Outlined.Upload) },
                        onClick = { addMenu = false; uploadPicker.launch(arrayOf("*/*")) },
                    )
                    DropdownMenuItem(
                        text = { Text("New folder") },
                        leadingIcon = { MenuIcon(Icons.Outlined.CreateNewFolder) },
                        onClick = { addMenu = false; createName = ""; creating = CreateKind.FOLDER },
                    )
                    DropdownMenuItem(
                        text = { Text("New file") },
                        leadingIcon = { MenuIcon(Icons.AutoMirrored.Outlined.NoteAdd) },
                        onClick = { addMenu = false; createName = ""; creating = CreateKind.FILE },
                    )
                }
            }
        })
        val list = nodes
        when {
            error != null -> CenteredNote(error ?: "")
            list == null -> LoadingBox()
            else -> {
                if (list.isNotEmpty()) TextField(
                    value = query, onValueChange = { query = it }, singleLine = true,
                    placeholder = { Text("Filter this folder", color = MyMuColors.mutedText) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    colors = fieldColors(),
                )
                val filtered = if (query.isBlank()) list
                else list.filter { it.name.contains(query.trim(), ignoreCase = true) }
                RefreshableList(refreshing, onRefresh = {
                    scope.launch { refreshing = true; refresh(); refreshing = false }
                }) {
                    // Empty folders still pull-to-refresh (the note rides a list item).
                    LazyColumn(Modifier.fillMaxSize()) {
                        if (list.isEmpty()) item(key = "empty") {
                            Text("No files.", color = MyMuColors.mutedText,
                                modifier = Modifier.fillMaxWidth().padding(top = 48.dp),
                                textAlign = TextAlign.Center)
                        }
                        items(filtered, key = { it.path }) { node ->
                            Box {
                                Row(
                                    Modifier
                                        .fillMaxWidth()
                                        .combinedClickable(
                                            onClick = {
                                                // Loaded levels travel with the route; only a
                                                // directory the tree walk didn't reach fetches
                                                // (iOS FileBrowser needsFetch split).
                                                if (node.isDir) onOpen(Route.Files(route.projectId, node.name,
                                                    node.path, route.origin, route.tokenOverride,
                                                    preloaded = if (node.needsFetch) null else node.sortedChildren))
                                                else onOpen(Route.FilePreview(route.projectId, node.name,
                                                    node.path, route.origin, route.tokenOverride))
                                            },
                                            onLongClick = { Haptics.attention(); menuFor = node },
                                        )
                                        .padding(horizontal = 16.dp, vertical = 10.dp),
                                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        if (node.isDir) Icons.Outlined.Folder else fileIcon(node.name),
                                        contentDescription = null,
                                        tint = if (node.isDir) MyMuColors.primary else MyMuColors.mutedText,
                                        modifier = Modifier.size(20.dp),
                                    )
                                    Spacer(Modifier.width(10.dp))
                                    Text(node.name, color = MyMuColors.text,
                                        style = MaterialTheme.typography.bodyLarge, maxLines = 1,
                                        modifier = Modifier.weight(1f))
                                    if (downloadingPath == node.path) {
                                        CircularProgressIndicator(Modifier.size(14.dp),
                                            color = MyMuColors.primary, strokeWidth = 2.dp)
                                    } else if (node.isDir) {
                                        Icon(Icons.Outlined.KeyboardArrowRight, contentDescription = null,
                                            tint = MyMuColors.mutedText, modifier = Modifier.size(16.dp))
                                    }
                                }
                                // Long-press menu (iOS contextMenu), anchored on the row.
                                DropdownMenu(expanded = menuFor == node,
                                    onDismissRequest = { menuFor = null }) {
                                    if (!node.isDir) DropdownMenuItem(
                                        text = { Text("Download") },
                                        leadingIcon = { MenuIcon(Icons.Outlined.Download) },
                                        onClick = {
                                            menuFor = null
                                            // Bytes → cache file under the REAL name → share
                                            // sheet; no need to open the preview first.
                                            scope.launch {
                                                downloadingPath = node.path
                                                try {
                                                    val bytes = api.fileData(route.projectId, node.path)
                                                    ShareSheet.shareFile(context, node.name, bytes)
                                                } catch (e: Exception) {
                                                    actionError = "Couldn't download ${node.name}. ${e.message ?: ""}".trim()
                                                }
                                                downloadingPath = null
                                            }
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Rename") },
                                        leadingIcon = { MenuIcon(Icons.Outlined.Edit) },
                                        onClick = { menuFor = null; renameText = node.name; renaming = node },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Copy path") },
                                        leadingIcon = { MenuIcon(Icons.Outlined.ContentCopy) },
                                        onClick = {
                                            menuFor = null
                                            clipboard.setText(AnnotatedString(node.path))
                                        },
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Delete", color = MyMuColors.danger) },
                                        leadingIcon = { MenuIcon(Icons.Outlined.Delete, MyMuColors.danger) },
                                        onClick = { menuFor = null; deleting = node },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    creating?.let { kind ->
        NameDialog(
            title = if (kind == CreateKind.FOLDER) "New folder" else "New file",
            confirm = "Create", value = createName, onValueChange = { createName = it },
            onDismiss = { creating = null },
            onConfirm = {
                creating = null
                val name = createName.trim()
                if (name.isNotEmpty()) mutate("Couldn't create $name.") {
                    api.createFileEntry(route.projectId, folderPath, name, kind == CreateKind.FOLDER)
                }
            },
        )
    }
    renaming?.let { node ->
        NameDialog(
            title = "Rename", confirm = "Rename", value = renameText,
            onValueChange = { renameText = it },
            onDismiss = { renaming = null },
            onConfirm = {
                renaming = null
                val name = renameText.trim()
                if (name.isNotEmpty() && name != node.name) mutate("Couldn't rename ${node.name}.") {
                    api.renameFileEntry(route.projectId, node.path, name)
                }
            },
        )
    }
    deleting?.let { node ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete ${node.name}?") },
            text = {
                Text(if (node.isDir) "The folder and everything inside it will be deleted on the server."
                     else "The file will be deleted on the server.")
            },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    mutate("Couldn't delete ${node.name}.") { api.deleteFileEntry(route.projectId, node.path) }
                }) { Text("Delete", color = MyMuColors.danger) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
            containerColor = MyMuColors.surface,
            titleContentColor = MyMuColors.text,
            textContentColor = MyMuColors.mutedText,
        )
    }
    actionError?.let { msg ->
        AlertDialog(
            onDismissRequest = { actionError = null },
            title = { Text("That didn't work.") },
            text = { Text(msg) },
            confirmButton = { TextButton(onClick = { actionError = null }) { Text("OK") } },
            containerColor = MyMuColors.surface,
            titleContentColor = MyMuColors.text,
            textContentColor = MyMuColors.mutedText,
        )
    }
}

@Composable
private fun MenuIcon(icon: ImageVector, tint: Color = MyMuColors.mutedText) {
    Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
}

@Composable
private fun fieldColors() = TextFieldDefaults.colors(
    focusedContainerColor = MyMuColors.surface,
    unfocusedContainerColor = MyMuColors.surface,
    focusedTextColor = MyMuColors.text,
    unfocusedTextColor = MyMuColors.text,
    cursorColor = MyMuColors.primary,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent,
)

/** Single-field name prompt (iOS alert-with-TextField): create + rename. */
@Composable
private fun NameDialog(
    title: String, confirm: String, value: String, onValueChange: (String) -> Unit,
    onDismiss: () -> Unit, onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            TextField(
                value = value, onValueChange = onValueChange, singleLine = true,
                placeholder = { Text("Name", color = MyMuColors.mutedText) },
                // Paths, not prose: no autocorrect, no auto-capitalisation.
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false,
                    capitalization = KeyboardCapitalization.None),
                colors = fieldColors(),
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = value.isNotBlank()) { Text(confirm) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        containerColor = MyMuColors.surface,
        titleContentColor = MyMuColors.text,
        textContentColor = MyMuColors.mutedText,
    )
}

/** SAF document display name (the picked file's real name), if the provider has one. */
private fun displayName(context: android.content.Context, uri: Uri): String? = try {
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
} catch (_: Exception) { null } ?: uri.lastPathSegment?.substringAfterLast('/')

/** Text preview (monospace) or inline media for a single file. */
@Composable
fun FilePreviewScreen(route: Route.FilePreview, onBack: () -> Unit) {
    val token = route.tokenOverride ?: AppState.token.collectAsStateWithLifecycle().value ?: return
    val api = remember(route) { ApiClient(token, route.origin) }
    val ext = route.name.substringAfterLast('.', "").lowercase()
    val isImage = ext in setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "bmp")
    val isVideo = ext in setOf("mp4", "mov", "m4v")
    val isAudio = ext in setOf("mp3", "wav", "m4a", "aac", "flac")
    val isMedia = isImage || isVideo || isAudio

    var text by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(!isMedia) }
    var error by remember { mutableStateOf<String?>(null) }
    var downloading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    LaunchedEffect(route) {
        if (isMedia) return@LaunchedEffect
        try { text = api.fileText(route.projectId, route.path) }
        catch (_: Exception) { error = "Can't preview this file." }
        loading = false
    }

    Column(Modifier.fillMaxSize()) {
        // Download/share rides the top bar (iOS FilesView toolbar, f5ad9a2):
        // raw bytes → tmp file under the REAL name → system share sheet.
        MyMuTopBar(route.name, onBack = onBack, actions = {
            if (downloading) {
                CircularProgressIndicator(Modifier.size(18.dp),
                    color = MyMuColors.primary, strokeWidth = 2.dp)
            } else {
                IconButton(onClick = {
                    scope.launch {
                        downloading = true
                        try {
                            val bytes = api.fileData(route.projectId, route.path)
                            ShareSheet.shareFile(context, route.name, bytes)
                        } catch (_: Exception) {
                            Toast.makeText(context, "Couldn’t download the file.",
                                Toast.LENGTH_SHORT).show()
                        }
                        downloading = false
                    }
                }) {
                    Icon(Icons.Outlined.IosShare,
                        contentDescription = "Download and share this file",
                        tint = MyMuColors.primary)
                }
            }
        })
        when {
            isMedia -> {
                val url = Config.fileStreamUrl(route.projectId, route.path, token,
                    delivered = false, origin = route.origin)
                Column(Modifier.padding(16.dp)) {
                    when {
                        isImage -> RemoteImage(url, zoomable = true,
                            modifier = Modifier.fillMaxWidth()) { FileLinkChip(route.name) }
                        isVideo -> VideoBubble(url)
                        else -> AudioBubble(url, route.name)
                    }
                }
            }
            loading -> LoadingBox()
            error != null -> CenteredNote(error ?: "", danger = true)
            // Selectable like the iOS preview (FilesView.swift:179).
            else -> SelectionContainer {
                Text(
                    text ?: "",
                    color = MyMuColors.text, fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp),
                )
            }
        }
    }
}
