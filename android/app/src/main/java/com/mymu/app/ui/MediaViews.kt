package com.mymu.app.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaPlayer
import android.net.Uri
import android.util.Base64
import android.util.LruCache
import android.widget.MediaController
import android.widget.Toast
import android.widget.VideoView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.IosShare
import androidx.compose.material.icons.outlined.Image as ImageIcon
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.mymu.app.core.ApiClient
import com.mymu.app.core.Config
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request

/** Process-wide decoded-image cache — scroll-back is instant, no re-download. */
private object RemoteImageCache {
    val cache = LruCache<String, Bitmap>(48)
}

/** Decode `data` at a bounded pixel size so a transcript with several images
 * can't spike memory (agents deliver multi-MB renders). */
fun downsampledBitmap(data: ByteArray, maxPixel: Int = 1600): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) > maxPixel || bounds.outHeight / (sample * 2) > maxPixel) {
        sample *= 2
    }
    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    return BitmapFactory.decodeByteArray(data, 0, data.size, opts)
}

/**
 * Authenticated remote image (port of iOS RemoteImage): loads over OkHttp,
 * caches the decoded bitmap process-wide, retries on re-appearance, and
 * downsamples huge renders.
 */
@Composable
fun RemoteImage(url: String, zoomable: Boolean = false, modifier: Modifier = Modifier,
                failure: @Composable () -> Unit) {
    var bitmap by remember(url) { mutableStateOf(RemoteImageCache.cache.get(url)) }
    var failed by remember(url) { mutableStateOf(false) }
    var lightbox by remember { mutableStateOf(false) }

    LaunchedEffect(url) {
        if (bitmap != null) return@LaunchedEffect
        val loaded = withContext(Dispatchers.IO) {
            try {
                ApiClient.http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                    if (resp.code != 200) return@withContext null
                    resp.body?.bytes()?.let { downsampledBitmap(it) }
                }
            } catch (_: Exception) { null }
        }
        if (loaded != null) {
            RemoteImageCache.cache.put(url, loaded)
            bitmap = loaded
        } else failed = true
    }

    val bmp = bitmap
    when {
        bmp != null -> {
            Image(
                bmp.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = modifier.let { m -> if (zoomable) m.clickable { lightbox = true } else m },
            )
            if (lightbox) ImageLightbox(bmp) { lightbox = false }
        }
        failed -> failure()
        else -> Box(modifier, contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(20.dp), color = MyMuColors.primary, strokeWidth = 2.dp)
        }
    }
}

/** Inline image from a `data:image/...;base64,...` URL — photos the user
 * attached to their own message. Decoded off the main thread, downsampled. */
@Composable
fun DataUrlImage(dataUrl: String, zoomable: Boolean = false, modifier: Modifier = Modifier) {
    var bitmap by remember(dataUrl) { mutableStateOf<Bitmap?>(null) }
    var failed by remember(dataUrl) { mutableStateOf(false) }
    var lightbox by remember { mutableStateOf(false) }

    LaunchedEffect(dataUrl) {
        if (bitmap != null) return@LaunchedEffect
        val decoded = withContext(Dispatchers.Default) {
            try {
                val comma = dataUrl.indexOf(',')
                if (!dataUrl.startsWith("data:") || comma < 0) null
                else downsampledBitmap(Base64.decode(dataUrl.substring(comma + 1), Base64.DEFAULT))
            } catch (_: Exception) { null }
        }
        if (decoded != null) bitmap = decoded else failed = true
    }

    val bmp = bitmap
    when {
        bmp != null -> {
            Image(bmp.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Fit,
                modifier = modifier.let { m -> if (zoomable) m.clickable { lightbox = true } else m })
            if (lightbox) ImageLightbox(bmp) { lightbox = false }
        }
        failed -> Icon(Icons.Outlined.ImageIcon, contentDescription = null, tint = MyMuColors.mutedText)
        else -> CircularProgressIndicator(Modifier.size(20.dp), color = MyMuColors.primary, strokeWidth = 2.dp)
    }
}

private val imageExts = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "avif")
private val videoExts = setOf("mp4", "mov", "m4v", "webm", "ogv")
private val audioExts = setOf("mp3", "wav", "m4a", "aac", "ogg", "opus", "flac", "oga")

/**
 * Inline preview of a file an agent delivered (SendUserFile). Streams from the
 * authenticated delivered-file endpoint (token in the query — media elements
 * can't set headers).
 */
@Composable
fun DeliveredMediaView(path: String, projectId: String, token: String, origin: String?) {
    val url = Config.fileStreamUrl(projectId, path, token, delivered = true, origin = origin)
    val ext = path.substringAfterLast('.', "").lowercase()
    val name = path.substringAfterLast('/')
    when {
        ext in imageExts ->
            // CONSTANT height, placeholder and loaded alike — a row's height
            // must never change after first layout (bottom-pin reflow bug).
            RemoteImage(url, zoomable = true,
                modifier = Modifier.height(240.dp).clip(RoundedCornerShape(12.dp))) {
                FileLinkChip(name)
            }
        ext in videoExts -> VideoBubble(url, name)
        ext in audioExts -> AudioBubble(url, name)
        else -> FileLinkChip(name)
    }
}

@Composable
fun FileLinkChip(name: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Outlined.Description, contentDescription = null,
            tint = MyMuColors.primary, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(5.dp))
        Text(name, color = MyMuColors.primary, style = MaterialTheme.typography.bodySmall)
    }
}

/** Inline video, platform VideoView (http streaming + seek, no extra deps).
 * The share button (iOS 4dee00b) downloads the file under its real [name] and
 * hands it to the share sheet — video was the one delivered medium with no
 * way off the phone (images have the lightbox). */
@Composable
fun VideoBubble(url: String, name: String = "") {
    // No name given (the files preview): the stream URL carries the file
    // path in its `path` query parameter (Config.fileStreamUrl).
    val fileName = name.ifEmpty {
        Uri.parse(url).getQueryParameter("path")?.substringAfterLast('/')?.takeIf { it.isNotEmpty() }
            ?: "video.mp4"
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var downloading by remember { mutableStateOf(false) }
    Box(
        Modifier
            .fillMaxWidth()
            .height(220.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black),
    ) {
        AndroidView(
            factory = { ctx ->
                VideoView(ctx).apply {
                    val controller = MediaController(ctx)
                    controller.setAnchorView(this)
                    setMediaController(controller)
                    setVideoPath(url)
                    seekTo(1) // show the first frame as a poster
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            Modifier
                .align(Alignment.TopEnd)
                .padding(8.dp)
                .size(32.dp)
                .background(Color.Black.copy(alpha = 0.5f), CircleShape)
                .clickable(enabled = !downloading) {
                    downloading = true
                    scope.launch {
                        try {
                            ShareSheet.shareDownload(context, fileName, url)
                        } catch (_: Exception) {
                            Toast.makeText(context, "Couldn't download the video.", Toast.LENGTH_SHORT).show()
                        }
                        downloading = false
                    }
                }
                .semantics { contentDescription = "Share video" },
            contentAlignment = Alignment.Center,
        ) {
            if (downloading) {
                CircularProgressIndicator(Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
            } else {
                Icon(Icons.Outlined.IosShare, contentDescription = null,
                    tint = Color.White, modifier = Modifier.size(16.dp))
            }
        }
    }
}

@Composable
fun AudioBubble(url: String, name: String) {
    var playing by remember { mutableStateOf(false) }
    val player = remember(url) { MediaPlayer() }
    var prepared by remember(url) { mutableStateOf(false) }

    DisposableEffect(url) {
        onDispose { player.release() }
    }

    Row(
        Modifier
            .fillMaxWidth()
            .background(MyMuColors.surface, RoundedCornerShape(12.dp))
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = {
            try {
                if (playing) { player.pause(); playing = false }
                else {
                    if (!prepared) {
                        player.setDataSource(url)
                        player.prepare()
                        prepared = true
                    }
                    player.start(); playing = true
                    player.setOnCompletionListener { playing = false }
                }
            } catch (_: Exception) { playing = false }
        }) {
            Icon(if (playing) Icons.Filled.PauseCircle else Icons.Filled.PlayCircle,
                contentDescription = if (playing) "Pause" else "Play",
                tint = MyMuColors.primary, modifier = Modifier.size(30.dp))
        }
        Text(name, color = MyMuColors.text, style = MaterialTheme.typography.bodySmall, maxLines = 1)
    }
}

/** Full-screen viewer for a tapped inline image: pinch to zoom (1–6x),
 * double-tap to toggle, pan while zoomed, X or tap-at-1x to close. */
@Composable
fun ImageLightbox(bitmap: Bitmap, onClose: () -> Unit) {
    var scale by remember { mutableStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    Dialog(onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black)
                .pointerInput(Unit) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(1f, 6f)
                        offset = if (scale > 1f) offset + pan else Offset.Zero
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures(
                        onDoubleTap = {
                            if (scale > 1f) { scale = 1f; offset = Offset.Zero } else scale = 3f
                        },
                        onTap = { if (scale <= 1.01f) onClose() },
                    )
                },
        ) {
            Image(
                bitmap.asImageBitmap(), contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer(
                        scaleX = scale, scaleY = scale,
                        translationX = offset.x, translationY = offset.y,
                    ),
            )
            Row(Modifier.align(Alignment.TopEnd).padding(10.dp)) {
                // Sharing the BITMAP puts image targets (save/send) in the
                // sheet — same reason the iOS lightbox shares the UIImage.
                IconButton(onClick = { scope.launch { ShareSheet.shareBitmap(context, bitmap) } }) {
                    Icon(Icons.Outlined.IosShare, contentDescription = "Share image",
                        tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(26.dp))
                }
                IconButton(onClick = onClose) {
                    Icon(Icons.Outlined.Close, contentDescription = "Close",
                        tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(28.dp))
                }
            }
        }
    }
}
