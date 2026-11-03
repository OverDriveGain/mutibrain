package com.manarz.myagent.chat

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** STUB — full-screen dictation: record → POST /transcribe → composer text (iOS Dictation.swift). */
object Dictation {
    enum class Phase { IDLE, RECORDING, TRANSCRIBING, FAILED }
    private val _phase = MutableStateFlow(Phase.IDLE)
    val phase: StateFlow<Phase> get() = _phase
    fun toggle() {}
    fun cancel() {}
}
