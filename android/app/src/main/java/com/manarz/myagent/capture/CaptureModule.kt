package com.manarz.myagent.capture

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

/** STUB — screenpipe screen + mic memory (MediaProjection + always-on mic). */
object CaptureModule {
    fun init(ctx: Context) {}
    /** Called on the home's first appearance (iOS AudioStreamer.autoStartIfEnabled). */
    fun autoStart(ctx: Context) {}
}

/** The Screenpipe page (iOS ScreenpipeView): screen broadcast + mic switches. */
@Composable
fun ScreenpipeScreen(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Screenpipe", color = Color.White) }
}

/** Starts the screen-capture consent flow from an Activity (the home's one-tap Screen button). */
object ScreenConsent { var request: (() -> Unit)? = null }
