package com.manarz.myagent.music

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

/** STUB — replaced by the Media3 player + the Music tab. Registers core.Music.host. */
object MusicModule { fun init(ctx: Context) {} }

@Composable
fun MusicScreen(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Music", color = Color.White) }
}
