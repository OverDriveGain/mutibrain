package com.mymu.app.core

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** A tapped notification's destination — MainTabs converts it into the Agents
 * tab + an open conversation (iOS: PushManager.pendingTarget/ChatTarget). */
data class PushTarget(val sessionId: String, val projectId: String, val title: String)

/**
 * The client half of agent-reply push notifications — Android counterpart of
 * iOS Core/PushManager.swift, speaking the same server contract
 * (POST/DELETE /api/push/register, payload carrying sessionId + projectId,
 * alert title = agent name) with an FCM registration token instead of an
 * APNs one (`platform: "android"`).
 *
 * Everything here is safe with no Firebase project configured: without
 * google-services.json the default FirebaseApp never initialises, `enable()`
 * swallows the failure, no token exists, and no registration is ever sent.
 */
object PushManager {
    /** Set when the user taps a notification; MainTabs navigates and clears it. */
    val pendingTarget = MutableStateFlow<PushTarget?>(null)

    /** FCM registration token once Firebase hands it over; re-registered
     * against every saved account's server (each host pushes for its agents). */
    private var deviceToken: String? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /**
     * Fetch the FCM token and register everywhere. Called when the signed-in
     * UI appears (after the POST_NOTIFICATIONS prompt on 33+) — a token fetch
     * is independent of that permission; denied just means silent delivery.
     */
    fun enable(context: Context) {
        try {
            if (FirebaseApp.getApps(context).isEmpty()) {
                // Returns null (and getInstance below throws) when the app has
                // no google-services.json — the whole feature stays off.
                FirebaseApp.initializeApp(context)
            }
            FirebaseMessaging.getInstance().token.addOnSuccessListener { tokenReceived(it) }
        } catch (_: Exception) {
            // Firebase not configured — push stays off, app works as before.
        }
    }

    /** FCM delivered (or rotated) the registration token. */
    fun tokenReceived(token: String) {
        deviceToken = token
        registerEverywhere()
    }

    /** Idempotent: safe to call again after adding an account or re-login.
     * Best-effort per host, a dead host skips. */
    fun registerEverywhere() {
        val token = deviceToken ?: return
        for (acct in AppState.accounts.value) {
            val auth = AppState.tokenFor(acct) ?: continue
            scope.launch {
                try { ApiClient(auth, acct.serverOrigin).pushRegister(token) } catch (_: Exception) {}
            }
        }
    }

    /** Sign-out of one account: stop that server pushing to this device. */
    fun unregister(account: SavedAccount, authToken: String) {
        val token = deviceToken ?: return
        scope.launch {
            try { ApiClient(authToken, account.serverOrigin).pushUnregister(token) } catch (_: Exception) {}
        }
    }

    /** Tap on a notification → open that conversation. The payload carries
     * the session/project ids; the alert title IS the agent name, reused as
     * the chat title (same value the roster would supply). */
    fun handleTap(sessionId: String?, projectId: String?, title: String?) {
        if (sessionId.isNullOrEmpty()) return
        pendingTarget.value = PushTarget(
            sessionId = sessionId,
            projectId = projectId?.takeIf { it.isNotEmpty() } ?: "remote:$sessionId",
            title = title?.takeIf { it.isNotEmpty() } ?: "Agent",
        )
    }
}
