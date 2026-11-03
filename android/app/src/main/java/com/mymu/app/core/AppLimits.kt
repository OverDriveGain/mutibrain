package com.mymu.app.core

import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Server-authoritative file-size caps (GET /api/limits) — the composer never
 * hardcodes the attachment cap. (Port of iOS Core/AppLimits.swift.)
 */
object AppLimits {
    /** Fallback when the server predates /api/limits: 64 MB. */
    private const val FALLBACK_BYTES = 64 * 1024 * 1024

    val attachmentBytes = MutableStateFlow(FALLBACK_BYTES)

    suspend fun refresh(api: ApiClient) {
        val remote = try { api.attachmentLimitBytes() } catch (_: Exception) { 0 }
        if (remote > 0) attachmentBytes.value = remote
    }
}
