package com.manarz.myagent.music

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.SubcomposeAsyncImage
import kotlinx.coroutines.launch

private val Stage = Color(0xFF050608)
private val Accent = Color(0xFF8E7BFF)
private val Muted = Color.White.copy(alpha = 0.55f)
private val Faint = Color.White.copy(alpha = 0.35f)
private val Panel = Color(0xFF12111B)

private enum class Mode(val label: String) { BROWSE("Browse"), QUEUE("Queue"), PLAYLISTS("Playlists") }

/** The Music tab — Android port of iOS MusicView (Browse / Queue / Playlists + now playing). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MusicScreen(modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val queue by MusicPlayer.queue.collectAsState()
    val index by MusicPlayer.index.collectAsState()
    var mode by rememberSaveable { mutableStateOf(Mode.BROWSE) }
    var query by rememberSaveable { mutableStateOf("") }
    var results by remember { mutableStateOf<MusicApi.Results?>(null) }
    var albums by remember { mutableStateOf<List<Album>>(emptyList()) }
    var playlists by remember { mutableStateOf<List<Playlist>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var showDownloads by rememberSaveable { mutableStateOf(false) }
    var savePrompt by remember { mutableStateOf(false) }
    var describe by remember { mutableStateOf<Playlist?>(null) }

    fun run(block: suspend () -> Unit) = scope.launch {
        loading = true
        runCatching { block() }.onFailure { error = it.message ?: "Couldn't reach the server" }
        loading = false
    }
    fun loadAlbums() = run { error = null; albums = MusicApi.albumWall() }
    fun loadPlaylists() = scope.launch { runCatching { playlists = MusicApi.playlists() } }
    fun search() {
        if (query.isBlank()) return
        focus.clearFocus()
        run { error = null; results = MusicApi.search(query.trim()) }
    }
    fun playOrQueue(queueOnly: Boolean, fetch: suspend () -> List<Song>) = run {
        val t = fetch()
        if (t.isNotEmpty()) if (queueOnly) MusicPlayer.addToQueue(t) else MusicPlayer.play(t)
    }

    LaunchedEffect(Unit) { loadAlbums(); loadPlaylists() }
    LaunchedEffect(mode) { if (mode == Mode.PLAYLISTS) loadPlaylists() }

    val songMenu: SongMenu = { song -> songMenuItems(song, playlists) { pl -> scope.launch { MusicApi.addToPlaylist(pl.id, song.id); loadPlaylists() } } }

    if (showDownloads) {
        BackHandler { showDownloads = false }
        DownloadsPage(onBack = { showDownloads = false }, modifier)
        return
    }

    Column(modifier.fillMaxSize().background(Stage).statusBarsPadding()) {
        // ---- title row
        Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 8.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Music", color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (loading) CircularProgressIndicator(Modifier.size(18.dp), color = Accent, strokeWidth = 2.dp)
            if (mode == Mode.QUEUE && queue.isNotEmpty()) TextButton(onClick = { savePrompt = true }) { Text("Save", color = Accent) }
        }
        // ---- mode picker
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            Mode.entries.forEachIndexed { i, m ->
                SegmentedButton(selected = mode == m, onClick = { mode = m },
                    shape = SegmentedButtonDefaults.itemShape(i, Mode.entries.size),
                    colors = SegmentedButtonDefaults.colors(activeContainerColor = Accent.copy(alpha = 0.3f),
                        activeContentColor = Color.White, inactiveContainerColor = Stage, inactiveContentColor = Muted),
                    icon = {}) { Text(m.label) }
            }
        }
        // ---- search (Browse)
        if (mode == Mode.BROWSE) OutlinedTextField(
            value = query,
            onValueChange = { query = it; if (it.isEmpty()) { results = null; loadAlbums() } },
            singleLine = true,
            placeholder = { Text("Songs, albums, artists…", color = Faint) },
            leadingIcon = { Icon(Icons.Filled.Search, null, tint = Muted) },
            trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = ""; results = null; loadAlbums() }) { Icon(Icons.Filled.Close, "Clear", tint = Muted) } },
            keyboardOptions = KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { search() }),
            shape = RoundedCornerShape(14.dp),
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Accent, unfocusedBorderColor = Color.White.copy(alpha = 0.12f),
                focusedTextColor = Color.White, unfocusedTextColor = Color.White, cursorColor = Accent),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        )

        Box(Modifier.weight(1f)) {
            when {
                error != null && mode == Mode.BROWSE -> Unavailable(error!!)
                mode == Mode.BROWSE -> {
                    val r = results
                    if (r != null && (r.songs.isNotEmpty() || r.albums.isNotEmpty() || r.artists.isNotEmpty())) {
                        LazyColumn(contentPadding = PaddingValues(bottom = 12.dp)) {
                            if (r.artists.isNotEmpty()) section("Artists") {
                                r.artists.forEach { ar ->
                                    item(key = "ar-${ar.id}") {
                                        CollectionRow(ar.coverUrl, ar.name ?: "Artist", "Artist", round = true,
                                            onPlay = { playOrQueue(false) { MusicApi.artist(ar.name ?: "") } },
                                            onQueue = { playOrQueue(true) { MusicApi.artist(ar.name ?: "") } })
                                    }
                                }
                            }
                            if (r.albums.isNotEmpty()) section("Albums") {
                                r.albums.forEach { al ->
                                    item(key = "al-${al.id}") {
                                        CollectionRow(al.coverUrl, al.name ?: "Album", al.artist ?: "",
                                            onPlay = { playOrQueue(false) { MusicApi.album(al.id) } },
                                            onQueue = { playOrQueue(true) { MusicApi.album(al.id) } })
                                    }
                                }
                            }
                            if (r.songs.isNotEmpty()) section("Songs") {
                                itemsIndexed(r.songs, key = { _, s -> "s-${s.id}" }) { i, s ->
                                    SongRow(s, playing = MusicPlayer.current?.id == s.id, menu = songMenu) { MusicPlayer.play(r.songs, i) }
                                }
                            }
                        }
                    } else if (r != null) {
                        Unavailable("Nothing found for “$query”.")
                    } else {
                        LazyVerticalGrid(GridCells.Adaptive(150.dp), contentPadding = PaddingValues(16.dp),
                            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            items(albums, key = { it.id }) { al ->
                                AlbumCell(al, onPlay = { playOrQueue(false) { MusicApi.album(al.id) } },
                                    onQueue = { playOrQueue(true) { MusicApi.album(al.id) } })
                            }
                        }
                    }
                }
                mode == Mode.QUEUE -> if (queue.isEmpty()) Unavailable("Nothing queued yet — play something from Browse.") else
                    LazyColumn {
                        itemsIndexed(queue, key = { i, s -> "$i-${s.id}" }) { i, s ->
                            SongRow(s, playing = i == index, menu = { _ ->
                                buildList {
                                    if (i > 0) add(MenuItem("Move up", Icons.Filled.ArrowUpward) { MusicPlayer.move(i, i - 1) })
                                    if (i < queue.size - 1) add(MenuItem("Move down", Icons.Filled.ArrowDownward) { MusicPlayer.move(i, i + 1) })
                                    add(MenuItem("Remove from queue", Icons.Filled.Delete, destructive = true) { MusicPlayer.removeAt(i) })
                                    addAll(songMenuItems(s, playlists) { pl -> scope.launch { MusicApi.addToPlaylist(pl.id, s.id); loadPlaylists() } }
                                        .filter { it.label != "Play" && it.label != "Add to queue" })
                                }
                            }) { MusicPlayer.playAt(i) }
                        }
                    }
                else -> PlaylistsList(playlists,
                    onDownloads = { showDownloads = true },
                    onPlay = { pl, q -> playOrQueue(q) { MusicApi.playlist(pl.id) } },
                    onDescribe = { describe = it },
                    onDelete = { pl -> scope.launch { MusicApi.delete(pl.id); loadPlaylists() } })
            }
        }
        if (queue.isNotEmpty()) NowPlayingBar()
    }

    if (savePrompt) TwoFieldDialog("Save playlist", "Save the current queue as a playlist.", "Name", "Description (optional)", "", "",
        onDismiss = { savePrompt = false }) { name, desc ->
        savePrompt = false
        if (name.isNotBlank()) scope.launch { MusicApi.savePlaylist(name.trim(), queue.map { it.id }, desc.trim()); loadPlaylists() }
    }
    describe?.let { pl ->
        TwoFieldDialog("Describe playlist", pl.name ?: "", "What is it good for?", null, pl.comment ?: "", "",
            onDismiss = { describe = null }) { text, _ ->
            describe = null
            scope.launch { MusicApi.describe(pl.id, text); loadPlaylists() }
        }
    }
}

// ---------------------------------------------------------------- menus

private class MenuItem(val label: String, val icon: ImageVector, val destructive: Boolean = false, val sub: List<MenuItem>? = null,
                       val onClick: () -> Unit = {})
private typealias SongMenu = (Song) -> List<MenuItem>

private fun songMenuItems(song: Song, playlists: List<Playlist>, addTo: (Playlist) -> Unit): List<MenuItem> = buildList {
    add(MenuItem("Play", Icons.Filled.PlayArrow) { MusicPlayer.play(listOf(song)) })
    add(MenuItem("Add to queue", Icons.AutoMirrored.Filled.QueueMusic) { MusicPlayer.addToQueue(listOf(song)) })
    when {
        DownloadStore.isDownloaded(song.id) -> add(MenuItem("Remove download", Icons.Filled.Delete, destructive = true) { DownloadStore.remove(song.id) })
        song.id !in DownloadStore.inFlight.value -> add(MenuItem("Download", Icons.Filled.Download) { DownloadStore.download(song) })
    }
    if (playlists.isNotEmpty()) add(MenuItem("Add to playlist", Icons.AutoMirrored.Filled.PlaylistAdd,
        sub = playlists.map { pl -> MenuItem(pl.name ?: "Playlist", Icons.Filled.LibraryMusic) { addTo(pl) } }))
}

/** A row that plays on tap and opens its menu on long-press (iOS contextMenu). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MenuRow(items: () -> List<MenuItem>, onTap: () -> Unit, content: @Composable () -> Unit) {
    var open by remember { mutableStateOf(false) }
    var subOf by remember { mutableStateOf<MenuItem?>(null) }
    Box {
        Box(Modifier.fillMaxWidth().combinedClickable(onClick = onTap, onLongClick = { open = true })) { content() }
        DropdownMenu(open, onDismissRequest = { open = false; subOf = null }, modifier = Modifier.background(Panel)) {
            val list = subOf?.sub ?: items()
            list.forEach { mi ->
                DropdownMenuItem(
                    text = { Text(mi.label, color = if (mi.destructive) Color(0xFFFF6B6B) else Color.White) },
                    leadingIcon = { Icon(mi.icon, null, tint = if (mi.destructive) Color(0xFFFF6B6B) else Muted) },
                    onClick = { if (mi.sub != null) subOf = mi else { open = false; subOf = null; mi.onClick() } },
                )
            }
        }
    }
}

// ---------------------------------------------------------------- rows

private fun LazyListScope.section(title: String, content: LazyListScope.() -> Unit) {
    item(key = "h-$title") {
        Text(title.uppercase(), color = Muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 18.dp, top = 14.dp, bottom = 4.dp))
    }
    content()
}

@Composable
private fun SongRow(song: Song, playing: Boolean, menu: SongMenu, onTap: () -> Unit) {
    val downloaded by DownloadStore.songs.collectAsState()
    val inFlight by DownloadStore.inFlight.collectAsState()
    MenuRow({ menu(song) }, onTap) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Cover(song.coverUrl, 44.dp)
            Column(Modifier.weight(1f)) {
                Text(song.displayTitle, color = if (playing) Accent else Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(song.displayArtist, color = Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            when {
                downloaded.any { it.id == song.id } -> Icon(Icons.Filled.DownloadDone, "Downloaded", tint = Faint, modifier = Modifier.size(16.dp))
                song.id in inFlight -> CircularProgressIndicator(Modifier.size(14.dp), color = Muted, strokeWidth = 2.dp)
            }
            if (playing) Icon(Icons.AutoMirrored.Filled.VolumeUp, "Playing", tint = Accent, modifier = Modifier.size(18.dp))
            else song.duration?.let { Text(mmss(it), color = Muted, fontSize = 12.sp) }
        }
    }
}

@Composable
private fun CollectionRow(cover: String?, title: String, subtitle: String, round: Boolean = false, onPlay: () -> Unit, onQueue: () -> Unit) {
    MenuRow({ listOf(MenuItem("Play", Icons.Filled.PlayArrow, onClick = onPlay), MenuItem("Add to queue", Icons.AutoMirrored.Filled.QueueMusic, onClick = onQueue)) }, onPlay) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Cover(cover, 44.dp, round)
            Column(Modifier.weight(1f)) {
                Text(title, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (subtitle.isNotEmpty()) Text(subtitle, color = Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Icon(Icons.Filled.PlayCircleOutline, null, tint = Accent)
        }
    }
}

@Composable
private fun AlbumCell(album: Album, onPlay: () -> Unit, onQueue: () -> Unit) {
    MenuRow({ listOf(MenuItem("Play", Icons.Filled.PlayArrow, onClick = onPlay), MenuItem("Add to queue", Icons.AutoMirrored.Filled.QueueMusic, onClick = onQueue)) }, onPlay) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(10.dp))) { Cover(album.coverUrl, null) }
            Text(album.name ?: "", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(album.artist ?: "", color = Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun PlaylistsList(playlists: List<Playlist>, onDownloads: () -> Unit, onPlay: (Playlist, Boolean) -> Unit,
                          onDescribe: (Playlist) -> Unit, onDelete: (Playlist) -> Unit) {
    val downloaded by DownloadStore.songs.collectAsState()
    LazyColumn(contentPadding = PaddingValues(bottom = 12.dp)) {
        item {
            Row(Modifier.fillMaxWidth().combinedClickableCompat(onDownloads).padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)).background(Accent.copy(alpha = 0.15f)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.DownloadDone, null, tint = Accent)
                }
                Column {
                    Text("Downloaded", color = Color.White)
                    Text("${downloaded.size} songs, plays offline", color = Muted, fontSize = 12.sp)
                }
            }
        }
        item {
            Text("PLAYLISTS", color = Muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 18.dp, top = 14.dp, bottom = 4.dp))
        }
        if (playlists.isEmpty()) item {
            Text("No saved playlists yet — make a queue and tap Save.", color = Muted, fontSize = 14.sp,
                modifier = Modifier.padding(horizontal = 18.dp, vertical = 8.dp))
        }
        playlists.forEach { pl ->
            item(key = pl.id) {
                MenuRow({
                    listOf(MenuItem("Play", Icons.Filled.PlayArrow) { onPlay(pl, false) },
                        MenuItem("Add to queue", Icons.AutoMirrored.Filled.QueueMusic) { onPlay(pl, true) },
                        MenuItem("Describe", Icons.Filled.EditNote) { onDescribe(pl) },
                        MenuItem("Delete", Icons.Filled.Delete, destructive = true) { onDelete(pl) })
                }, { onPlay(pl, false) }) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Cover(pl.coverUrl, 44.dp)
                        Column(Modifier.weight(1f)) {
                            Text(pl.name ?: "Playlist", color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            val count = "${pl.songCount ?: 0} songs"
                            Text(if (!pl.comment.isNullOrEmpty()) "${pl.comment} · $count" else count, color = Muted, fontSize = 12.sp,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(Icons.Filled.PlayCircleOutline, null, tint = Accent)
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadsPage(onBack: () -> Unit, modifier: Modifier) {
    val songs by DownloadStore.songs.collectAsState()
    val queue by MusicPlayer.queue.collectAsState()
    Column(modifier.fillMaxSize().background(Stage).statusBarsPadding()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White) }
            Text("Downloaded", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        }
        Box(Modifier.weight(1f)) {
            if (songs.isEmpty()) Unavailable("No downloads yet — long-press a song and tap Download,\nor say “download this song”.")
            else LazyColumn {
                itemsIndexed(songs, key = { _, s -> s.id }) { i, s ->
                    SongRow(s, playing = MusicPlayer.current?.id == s.id,
                        menu = { listOf(MenuItem("Remove download", Icons.Filled.Delete, destructive = true) { DownloadStore.remove(s.id) }) }) {
                        MusicPlayer.play(songs, i)
                    }
                }
            }
        }
        if (queue.isNotEmpty()) NowPlayingBar()
    }
}

// ---------------------------------------------------------------- now playing

@Composable
private fun NowPlayingBar() {
    val index by MusicPlayer.index.collectAsState()
    val queue by MusicPlayer.queue.collectAsState()
    val playing by MusicPlayer.isPlaying.collectAsState()
    val pos by MusicPlayer.position.collectAsState()
    val dur by MusicPlayer.duration.collectAsState()
    var scrub by remember { mutableStateOf<Float?>(null) }
    val song = queue.getOrNull(index) ?: return
    val length = dur.coerceAtLeast(1.0)
    Column(Modifier.fillMaxWidth().background(Panel).padding(bottom = 8.dp)) {
        Slider(
            value = scrub ?: (pos / length).toFloat().coerceIn(0f, 1f),
            onValueChange = { scrub = it },
            onValueChangeFinished = { scrub?.let { MusicPlayer.seek(it * length) }; scrub = null },
            colors = SliderDefaults.colors(thumbColor = Accent, activeTrackColor = Accent, inactiveTrackColor = Color.White.copy(alpha = 0.2f)),
            modifier = Modifier.fillMaxWidth().height(24.dp).padding(horizontal = 8.dp),
        )
        Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Cover(song.coverUrl, 44.dp)
            Column(Modifier.weight(1f)) {
                Text(song.displayTitle, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(song.displayArtist, color = Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, false))
                    Text("${fmt(scrub?.let { it * length } ?: pos)} / ${fmt(length)}", color = Faint, fontSize = 11.sp)
                }
            }
            IconButton(onClick = { MusicPlayer.prev() }) { Icon(Icons.Filled.SkipPrevious, "Previous", tint = Color.White) }
            IconButton(onClick = { MusicPlayer.toggle() }, modifier = Modifier.size(44.dp).clip(CircleShape).background(Accent.copy(alpha = 0.25f))) {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, if (playing) "Pause" else "Play", tint = Color.White)
            }
            IconButton(onClick = { MusicPlayer.next() }) { Icon(Icons.Filled.SkipNext, "Next", tint = Color.White) }
        }
    }
}

// ---------------------------------------------------------------- bits

@Composable
private fun Cover(url: String?, size: Dp?, round: Boolean = false) {
    val shape = if (round) CircleShape else RoundedCornerShape(8.dp)
    val m = (if (size != null) Modifier.size(size) else Modifier.fillMaxSize()).clip(shape)
    SubcomposeAsyncImage(
        model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = m,
        loading = { Placeholder(round) }, error = { Placeholder(round) },
    )
}

@Composable
private fun Placeholder(round: Boolean) {
    Box(Modifier.fillMaxSize().background(Color.White.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
        Icon(if (round) Icons.Filled.Person else Icons.Filled.MusicNote, null, tint = Faint)
    }
}

@Composable
private fun Unavailable(msg: String) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Filled.LibraryMusic, null, tint = Faint, modifier = Modifier.size(40.dp))
        Spacer(Modifier.height(10.dp))
        Text(msg, color = Muted, textAlign = TextAlign.Center, fontSize = 15.sp)
    }
}

@Composable
private fun TwoFieldDialog(title: String, message: String, label1: String, label2: String?, init1: String, init2: String,
                           onDismiss: () -> Unit, onSave: (String, String) -> Unit) {
    var a by remember { mutableStateOf(init1) }
    var b by remember { mutableStateOf(init2) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (message.isNotEmpty()) Text(message, fontSize = 14.sp)
                OutlinedTextField(a, { a = it }, singleLine = true, label = { Text(label1) })
                if (label2 != null) OutlinedTextField(b, { b = it }, singleLine = true, label = { Text(label2) })
            }
        },
        confirmButton = { TextButton(onClick = { onSave(a, b) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableCompat(onClick: () -> Unit) = this.combinedClickable(onClick = onClick)

private fun mmss(s: Int) = "%d:%02d".format(s / 60, s % 60)
private fun fmt(s: Double): String = if (!s.isFinite() || s < 0) "0:00" else s.toInt().let { "%d:%02d".format(it / 60, it % 60) }

