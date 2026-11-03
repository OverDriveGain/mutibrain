package com.mymu.app.ui

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.mymu.app.core.ApiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import okhttp3.Request

/**
 * Counterpart of the iOS ActivitySheet (Components.swift): hand a freshly
 * downloaded file — or the lightbox's rendered bitmap — to the system share
 * sheet. Files are parked in cacheDir/downloads under their REAL name (the
 * sheet shows that name and keeps the extension) and served through the
 * app's FileProvider; the cache dir means the OS reclaims leftovers.
 */
object ShareSheet {

    suspend fun shareFile(context: Context, name: String, bytes: ByteArray) {
        val file = withContext(Dispatchers.IO) {
            val dir = File(context.cacheDir, "downloads").apply { mkdirs() }
            File(dir, name.substringAfterLast('/').ifEmpty { "file" })
                .apply { writeBytes(bytes) }
        }
        launch(context, file, mimeFor(name))
    }

    /** Download [url] straight to cacheDir/downloads under [name] and share
     * it — the delivered-video share button (iOS 4dee00b VideoBubble). Streams
     * to disk instead of holding the bytes: videos run to tens of MB. Sharing
     * the stream URL itself is useless to other apps (the token in its query
     * dies with the session). Throws on a non-200 / network failure. */
    suspend fun shareDownload(context: Context, name: String, url: String) {
        val file = withContext(Dispatchers.IO) {
            val dir = File(context.cacheDir, "downloads").apply { mkdirs() }
            val dest = File(dir, name.substringAfterLast('/').ifEmpty { "file" })
            ApiClient.http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                val body = resp.body
                if (resp.code != 200 || body == null) throw IOException("HTTP ${resp.code}")
                dest.outputStream().use { out -> body.byteStream().use { it.copyTo(out) } }
            }
            dest
        }
        launch(context, file, mimeFor(name))
    }

    /** Sharing the decoded bitmap (not the URL) keeps this working for
     * authenticated images and puts image targets (save/send) in the sheet —
     * the iOS lightbox shares the UIImage for the same reason. */
    suspend fun shareBitmap(context: Context, bitmap: Bitmap) {
        val file = withContext(Dispatchers.IO) {
            val dir = File(context.cacheDir, "downloads").apply { mkdirs() }
            File(dir, "image-${System.currentTimeMillis()}.png").apply {
                outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
        launch(context, file, "image/png")
    }

    private fun launch(context: Context, file: File, mime: String) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files" /* HOST PATCH: host FileProvider */, file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, null))
    }

    private fun mimeFor(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }
}

/**
 * A content stream's byte size, learned WITHOUT reading it: the provider's
 * `OpenableColumns.SIZE`, else the descriptor length. SIZE is optional in the
 * OpenableColumns contract — a provider that omits it must not slip past the
 * "never read an oversized video into memory" guards (composer attach, share
 * screen). Null only when neither is knowable.
 */
internal fun knownContentSize(resolver: ContentResolver, uri: Uri): Long? {
    val declared = try {
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
        }
    } catch (_: Exception) { null }
    if (declared != null && declared >= 0) return declared
    return try {
        resolver.openAssetFileDescriptor(uri, "r")?.use { afd -> afd.length.takeIf { it >= 0 } }
    } catch (_: Exception) { null }
}
