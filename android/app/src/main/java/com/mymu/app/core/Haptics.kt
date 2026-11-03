package com.mymu.app.core

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * ChatGPT-style tactile feedback, Android edition of iOS Core/Haptics.swift:
 * a light tap going out, a soft tap when the agent starts answering, stronger
 * taps for permission asks, errors, and turn completion.
 */
@SuppressLint("StaticFieldLeak")
object Haptics {
    private var vibrator: Vibrator? = null

    fun init(context: Context) {
        vibrator = if (Build.VERSION.SDK_INT >= 31) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private fun effect(id: Int) {
        val v = vibrator ?: return
        // Feedback must NEVER take the app down — a missing permission or a
        // vibrator-less device degrades to silence, not a crash (field find:
        // the first live send crashed on VIBRATE before the permission landed).
        try {
            if (Build.VERSION.SDK_INT >= 29) v.vibrate(VibrationEffect.createPredefined(id))
        } catch (_: Exception) {}
    }

    fun send() = effect(VibrationEffect.EFFECT_CLICK)
    fun firstResponse() = effect(VibrationEffect.EFFECT_TICK)
    /** One detent of a picker-style control (the agent-switcher carousel). */
    fun tick() = effect(VibrationEffect.EFFECT_TICK)
    fun complete() = effect(VibrationEffect.EFFECT_DOUBLE_CLICK)
    fun attention() = effect(VibrationEffect.EFFECT_HEAVY_CLICK)
    fun error() = effect(VibrationEffect.EFFECT_HEAVY_CLICK)
}
