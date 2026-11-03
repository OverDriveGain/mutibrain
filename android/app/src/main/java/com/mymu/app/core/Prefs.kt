package com.mymu.app.core

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences

/**
 * App-wide key-value store — the Android counterpart of both UserDefaults and
 * the Keychain in the iOS app, with the SAME storage split: plain values stay
 * plain SharedPreferences; auth tokens ("auth-token", "auth-token|…") are
 * encrypted with an Android-Keystore AES key (TokenCrypto) the way iOS keeps
 * exactly those keys in the Keychain. Existing plaintext tokens migrate
 * silently on first launch. Keys deliberately mirror the iOS names so the two
 * clients stay diffable side by side; `allowBackup=false` additionally keeps
 * the store off cloud backups.
 */
@SuppressLint("StaticFieldLeak")
object Prefs {
    private lateinit var prefs: SharedPreferences

    /** Storage marker for a Keystore-encrypted value. */
    private const val ENC_PREFIX = "enc1:"

    private fun isTokenKey(key: String) =
        key == "auth-token" || key.startsWith("auth-token|")

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences("mymu", Context.MODE_PRIVATE)
        migrateTokens()
    }

    /** One-time, silent: any plaintext token found is rewritten encrypted. */
    private fun migrateTokens() {
        for ((key, value) in prefs.all) {
            if (!isTokenKey(key)) continue
            val raw = value as? String ?: continue
            if (raw.startsWith(ENC_PREFIX)) continue
            putString(key, raw)
        }
    }

    fun getString(key: String): String? {
        val raw = prefs.getString(key, null) ?: return null
        if (!isTokenKey(key)) return raw
        // Encrypted token: decrypt-or-nothing. A value the Keystore key can't
        // open (restored to another device) reads as signed-out, like an iOS
        // Keychain item that didn't migrate.
        if (raw.startsWith(ENC_PREFIX)) return TokenCrypto.decrypt(raw.removePrefix(ENC_PREFIX))
        return raw // plaintext legacy (or Keystore-less fallback) — still valid
    }

    fun putString(key: String, value: String?) {
        val stored = if (value != null && isTokenKey(key)) {
            // Keystore failure falls back to plaintext — never lose a login
            // to a broken vendor Keystore; migration retries next launch.
            TokenCrypto.encrypt(value)?.let { ENC_PREFIX + it } ?: value
        } else value
        prefs.edit().apply {
            if (stored == null) remove(key) else putString(key, stored)
        }.apply()
    }
}
