package com.manarz.myagent.core

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The app's config — the Android counterpart of iOS SharedConfig.swift.
 *
 * One process holds everything here (no app/extension split like iOS's
 * broadcast extension), so plain SharedPreferences are enough. Secrets are
 * NEVER committed: the build host bakes them into assets/baked.properties
 * (gitignored); the committed defaults are placeholders, exactly like the iOS
 * `__GADK_TOKEN__` sed-injection.
 */
object Config {
    private lateinit var prefs: SharedPreferences
    private lateinit var baked: Map<String, String>

    // ---- defaults (overridden by baked.properties, then by the user) ----
    const val DEFAULT_GADK = "https://agent.kaxtus.com/voice?app=manar&token=__GADK_TOKEN__"
    const val DEFAULT_SCREENPIPE_BASE = "https://screenpipe-home.kaxtus.com"
    const val DEFAULT_SCREENPIPE_AGENT = "android-manar"
    const val DEFAULT_MYMU_HOST = "https://code.kaxtus.com"
    const val DEFAULT_MYMU_AGENT = "special-agent"

    /** The tokenized voice URL; changes rebuild the whole UI (like iOS .id(gadkURL)). */
    private val _gadk = MutableStateFlow("")
    val gadkFlow: StateFlow<String> get() = _gadk

    fun init(ctx: Context) {
        prefs = ctx.getSharedPreferences("myagent", Context.MODE_PRIVATE)
        baked = runCatching {
            ctx.assets.open("baked.properties").use { s ->
                java.util.Properties().apply { load(s) }.let { p ->
                    p.stringPropertyNames().associateWith { p.getProperty(it) }
                }
            }
        }.getOrDefault(emptyMap())
        _gadk.value = gadkURL
    }

    private fun str(key: String, def: String): String =
        prefs.getString(key, null)?.takeIf { it.isNotBlank() } ?: baked[key]?.takeIf { it.isNotBlank() } ?: def

    var gadkURL: String
        get() = str("gadkURL", DEFAULT_GADK)
        set(v) { prefs.edit { putString("gadkURL", v.trim()) }; _gadk.value = gadkURL }

    var mymuHost: String
        get() = str("mymuHost", DEFAULT_MYMU_HOST)
        set(v) = prefs.edit { putString("mymuHost", v.trim()) }

    var mymuAgent: String
        get() = str("mymuAgent", DEFAULT_MYMU_AGENT)
        set(v) = prefs.edit { putString("mymuAgent", v.trim()) }

    /** The drawer's swipe roster, comma-joined, brain first (/config mymu.agents). */
    var mymuAgentsCSV: String
        get() = prefs.getString("mymuAgents", "") ?: ""
        set(v) = prefs.edit { putString("mymuAgents", v) }

    /** Legacy share-token chat URL (/config chatUrl) — BrainAccess falls back to it. */
    var chatURL: String
        get() = str("chatURL", "")
        set(v) = prefs.edit { putString("chatURL", v) }

    // screenpipe central (screen + mic memory)
    var screenpipeBase: String
        get() = str("serverBase", DEFAULT_SCREENPIPE_BASE)
        set(v) = prefs.edit { putString("serverBase", v.trim()) }
    var screenpipeToken: String
        get() = str("token", "")
        set(v) = prefs.edit { putString("token", v.trim()) }
    var screenpipeAgentId: String
        get() = str("agentId", DEFAULT_SCREENPIPE_AGENT)
        set(v) = prefs.edit { putString("agentId", v.trim()) }

    /** Stable per-install voice user id (iOS "ios-xxxxxxxx"). */
    val userId: String
        get() = prefs.getString("gadkUserId", null) ?: ("android-" + java.util.UUID.randomUUID().toString().take(8))
            .also { prefs.edit { putString("gadkUserId", it) } }

    fun bool(key: String, def: Boolean = false) = prefs.getBoolean(key, def)
    fun setBool(key: String, v: Boolean) = prefs.edit { putBoolean(key, v) }
    fun string(key: String): String? = prefs.getString(key, null)
    fun setString(key: String, v: String?) = prefs.edit { if (v == null) remove(key) else putString(key, v) }
}

/** (origin, app, token) parsed from the tokenized voice URL — iOS GadkVoice.Target. */
data class Target(val origin: String, val app: String, val token: String) {
    val hasToken get() = token.isNotEmpty() && !token.startsWith("__")

    /** `origin + path` with ?app=&token= (the auth every subscriber endpoint wants). */
    fun url(path: String, vararg extra: Pair<String, String>): String {
        val b = Uri.parse(origin + (if (path.startsWith("/")) path else "/$path")).buildUpon()
        b.appendQueryParameter("app", app)
        b.appendQueryParameter("token", token)
        for ((k, v) in extra) b.appendQueryParameter(k, v)
        return b.build().toString()
    }

    companion object {
        fun current(): Target = from(Config.gadkURL)

        fun from(raw: String): Target {
            val u = Uri.parse(raw)
            val scheme = u.scheme ?: "https"
            val port = if (u.port > 0) ":${u.port}" else ""
            return Target(
                origin = "$scheme://${u.host ?: "agent.kaxtus.com"}$port",
                app = u.getQueryParameter("app") ?: "manar",
                token = u.getQueryParameter("token") ?: "",
            )
        }
    }
}

/** The application context, for modules that need one outside a composable. */
object AppContext {
    private lateinit var app: android.content.Context
    fun set(c: android.content.Context) { app = c.applicationContext }
    fun get(): android.content.Context = app
}
