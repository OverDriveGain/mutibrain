package com.mymu.app.core

import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * One-shot delivery for the share screen: upload the shared files to the
 * server's asset store (same routes the composer uses), then a single
 * `chat.send` frame over a short-lived WebSocket. No streaming, no state —
 * the conversation catches up next time it's opened.
 *
 * Port of iOS MyMuShare/ShareSender.swift including its error contract: any
 * failure — asset upload, socket connect — THROWS instead of pretending
 * success, so the share sheet can tell "Sent" from "couldn't reach the server".
 */
object ShareSender {

    suspend fun send(
        note: String,
        /** `[{name, data: "data:<mime>;base64,…"}]` — the composer's shape. */
        attachments: List<Map<String, String>>,
        token: String,
        origin: String?,
        sessionId: String,
    ) {
        val images = mutableListOf<ApiClient.Attachment>()
        val files = mutableListOf<ApiClient.Attachment>()
        for (a in attachments) {
            val parsed = RelayClient.parseDataUrl(a["data"] ?: continue) ?: continue
            val entry = ApiClient.Attachment(a["name"] ?: "attachment", parsed.first, parsed.second)
            if (parsed.first.startsWith("image/")) images += entry else files += entry
        }

        val api = ApiClient(token, origin)
        val records = mutableListOf<ApiClient.AssetRecord>()
        if (images.isNotEmpty()) records += api.uploadAssets(images, "images")
        if (files.isNotEmpty()) records += api.uploadAssets(files, "files")

        val content = note.trim()
        if (content.isEmpty() && records.isEmpty()) return

        val options = JSONObject()
        if (records.isNotEmpty()) {
            val arr = JSONArray()
            for (r in records) arr.put(JSONObject().apply {
                put("path", r.path)
                r.name?.let { put("name", it) }
                r.mimeType?.let { put("mimeType", it) }
            })
            options.put("images", arr)
        }
        val frame = JSONObject()
            .put("type", "chat.send")
            .put("sessionId", sessionId)
            .put("content", content)
            .put("options", options)

        // OkHttp queues frames before the handshake finishes, so a send()
        // returning true proves nothing offline — success is the handshake
        // (onOpen) actually completing; onFailure is what a dead network says.
        val ws = suspendCancellableCoroutine<WebSocket> { cont ->
            val req = Request.Builder().url(Config.webSocketUrl(token, origin)).build()
            val socket = ApiClient.http.newWebSocket(req, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (cont.isActive) cont.resume(webSocket)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (cont.isActive) cont.resumeWithException(t)
                }
            })
            cont.invokeOnCancellation { socket.cancel() }
        }
        ws.send(frame.toString())
        // Give the frame a moment to be ingested before tearing the socket
        // down; the server acks by streaming, which the share flow doesn't need.
        delay(1_200)
        ws.close(1000, null)
    }
}
