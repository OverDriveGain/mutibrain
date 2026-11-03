package com.mymu.app.core

import android.net.Uri
import java.net.URI

/**
 * Server the app talks to. The native client uses the exact same REST + `/ws`
 * API the MyMu web client does, just pointed at a user-configurable origin.
 * (1:1 port of iOS Core/Config.swift.)
 */
object Config {
    const val DEFAULT_SERVER_ORIGIN = "https://demo.proagenten.de"
    private const val ORIGIN_KEY = "mymu.serverOrigin"

    var serverOrigin: String
        get() = Prefs.getString(ORIGIN_KEY) ?: DEFAULT_SERVER_ORIGIN
        set(value) { Prefs.putString(ORIGIN_KEY, normalize(value)) }

    /** Add https:// if missing, strip any path/trailing slash — keep scheme+host(+port). */
    fun normalize(raw: String): String {
        var s = raw.trim()
        if (s.isEmpty()) return DEFAULT_SERVER_ORIGIN
        if (!s.startsWith("http://") && !s.startsWith("https://")) s = "https://$s"
        return try {
            val u = URI(s)
            val host = u.host ?: return s
            val scheme = u.scheme ?: "https"
            if (u.port != -1) "$scheme://$host:${u.port}" else "$scheme://$host"
        } catch (_: Exception) {
            s
        }
    }

    /**
     * wss://host/ws — the single chat/live WebSocket the web client uses.
     * `origin` overrides the active server for a conversation routed to the
     * agent's assigned host (agent→host pinning); null = active account's host.
     */
    fun webSocketUrl(token: String, origin: String? = null): String {
        val wsOrigin = (origin ?: serverOrigin)
            .replace("https://", "wss://")
            .replace("http://", "ws://")
        return "$wsOrigin/ws?token=${Uri.encode(token)}"
    }

    /**
     * Authenticated streaming URL for a delivered/preview file (media can't set
     * an Authorization header, so the token rides as ?token= — the server accepts it).
     */
    fun fileStreamUrl(projectId: String, path: String, token: String, delivered: Boolean, origin: String? = null): String {
        val encodedId = Uri.encode(projectId)
        val base = if (delivered) "/api/projects/$encodedId/delivered-file"
        else "/api/file-tree/projects/$encodedId/files/content"
        return (origin ?: serverOrigin) + base +
            "?path=${Uri.encode(path)}&token=${Uri.encode(token)}"
    }
}
