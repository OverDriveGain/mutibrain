package com.mymu.app.core

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android Keystore encryption for auth tokens — the counterpart of iOS
 * Core/Keychain.swift. The AES-256-GCM key lives INSIDE the Keystore
 * (non-exportable, hardware-backed where the device has an enclave); Prefs
 * stores only iv:ciphertext, so a copied prefs XML is useless off-device.
 *
 * Failure policy mirrors what a login is worth:
 *  - encrypt failure → caller falls back to plaintext (never lose a login to
 *    a broken Keystore; rare, but real on some vendor builds);
 *  - decrypt failure → null (the key is gone, e.g. after a backup restore to
 *    another device — the token is unreadable and the user signs in again,
 *    exactly like an iOS Keychain item that didn't migrate).
 */
object TokenCrypto {
    private const val ALIAS = "mymu-token-key"
    private const val TRANSFORM = "AES/GCM/NoPadding"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    /** plaintext → "iv:ciphertext" (both base64), or null when the Keystore fails. */
    fun encrypt(plain: String): String? = try {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(ct, Base64.NO_WRAP)
    } catch (_: Exception) { null }

    /** "iv:ciphertext" → plaintext, or null when the key can't open it. */
    fun decrypt(payload: String): String? = try {
        val sep = payload.indexOf(':')
        if (sep <= 0) null else {
            val iv = Base64.decode(payload.substring(0, sep), Base64.NO_WRAP)
            val ct = Base64.decode(payload.substring(sep + 1), Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(ct), Charsets.UTF_8)
        }
    } catch (_: Exception) { null }
}
