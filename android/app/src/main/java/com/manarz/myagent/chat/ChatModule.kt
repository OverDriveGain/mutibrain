package com.manarz.myagent.chat

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

/** STUB — replaced by the vendored MyMu chat (the drawer under the swarm). */
object ChatModule {
    fun init(ctx: Context) {}
    /** Signed-in MyMu username (Settings shows it), null = signed out. */
    val user: String? get() = null
    fun signOut() {}
}

/** The open drawer's content: the brain's MyMu conversation. */
@Composable
fun DrawerChat(full: Boolean, onDictate: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Chat", color = Color.White) }
}

/** The closed drawer's peek row: the brain's name + state. */
@Composable
fun BrainPeek(modifier: Modifier = Modifier) {
    Box(modifier, contentAlignment = Alignment.CenterStart) { Text("special-agent", color = Color.White) }
}
