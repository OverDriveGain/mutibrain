package com.manarz.myagent.chat

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mymu.app.ui.MyMuColors

/** The full-height drawer's mic: dictation into the composer (iOS DictateButton). */
@Composable
internal fun DictateButton(modifier: Modifier, onClick: () -> Unit) {
    val phase by Dictation.phase.collectAsState()
    val pulse by rememberInfiniteTransition(label = "dict").animateFloat(1f, 0.45f,
        infiniteRepeatable(tween(600), RepeatMode.Reverse), label = "p")
    IconButton(onClick = onClick, enabled = phase != Dictation.Phase.TRANSCRIBING,
        modifier = modifier.size(34.dp).semantics {
            contentDescription = if (phase == Dictation.Phase.RECORDING) "Finish dictation" else "Dictate"
        }) {
        when (phase) {
            Dictation.Phase.RECORDING -> Icon(Icons.Filled.StopCircle, null, tint = Color(0xFFFF5966),
                modifier = Modifier.size(24.dp).alpha(pulse))
            Dictation.Phase.TRANSCRIBING -> CircularProgressIndicator(color = MyMuColors.primary, strokeWidth = 2.dp,
                modifier = Modifier.size(16.dp))
            else -> Icon(Icons.Filled.Mic, null, tint = MyMuColors.primary, modifier = Modifier.size(20.dp))
        }
    }
}

/** Recording / transcribing / failure strip under the dots (iOS DictationBar). */
@Composable
internal fun DictationBar() {
    val phase by Dictation.phase.collectAsState()
    val seconds by Dictation.seconds.collectAsState()
    val level by Dictation.level.collectAsState()
    val error by Dictation.error.collectAsState()
    if (phase == Dictation.Phase.IDLE) return
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        when (phase) {
            Dictation.Phase.RECORDING -> {
                Box(Modifier.size(8.dp).clip(CircleShape).background(Color.Red))
                Text("Listening · %d:%02d".format(seconds / 60, seconds % 60), color = MyMuColors.text,
                    fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Box(Modifier.width(120.dp).height(4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))) {
                    Box(Modifier.fillMaxHeight().width((6 + 114 * level).dp).clip(CircleShape).background(MyMuColors.primary))
                }
                Spacer(Modifier.weight(1f))
                Text("tap the mic to finish", color = MyMuColors.mutedText, fontSize = 12.sp)
            }
            Dictation.Phase.TRANSCRIBING -> {
                CircularProgressIndicator(color = MyMuColors.primary, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                Text("Transcribing…", color = MyMuColors.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
            Dictation.Phase.FAILED -> {
                Icon(Icons.Filled.ErrorOutline, null, tint = Color.Red, modifier = Modifier.size(16.dp))
                Text(error, color = Color.Red, fontSize = 13.sp, maxLines = 2)
            }
            Dictation.Phase.IDLE -> {}
        }
    }
}
