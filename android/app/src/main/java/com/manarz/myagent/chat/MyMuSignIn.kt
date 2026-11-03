package com.manarz.myagent.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.HowToReg
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mymu.app.core.AppState
import com.mymu.app.core.Config as MyMuConfig
import com.mymu.app.ui.MyMuColors
import kotlinx.coroutines.launch

/**
 * The drawer's sign-in (iOS MyMuSignIn): MyMu username + password against the
 * host the voice /config names; success opens the brain's conversation.
 */
@Composable
fun MyMuSignIn(host: String, agentName: String, initialUser: String? = null) {
    var origin by remember(host) { mutableStateOf(host) }
    var user by remember { mutableStateOf(initialUser ?: "") }
    var pass by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun signIn() {
        if (busy || user.isBlank() || pass.isEmpty()) return
        busy = true; error = null
        MyMuConfig.serverOrigin = MyMuConfig.normalize(origin)
        scope.launch {
            try {
                AppState.login(user.trim(), pass)
                AppState.reauthNeeded.value = null   // a pinned re-sign-in is satisfied too
                pass = ""
                loginBeacon(true)
                ChatModule.load(force = true)
            } catch (e: Exception) {
                error = e.message ?: "Sign-in failed"
                loginBeacon(false)
            }
            busy = false
        }
    }

    val colors = OutlinedTextFieldDefaults.colors(
        focusedTextColor = MyMuColors.text, unfocusedTextColor = MyMuColors.text,
        focusedBorderColor = MyMuColors.primary, unfocusedBorderColor = MyMuColors.border,
        focusedLabelColor = MyMuColors.primary, unfocusedLabelColor = MyMuColors.mutedText,
        cursorColor = MyMuColors.primary)

    Column(Modifier.fillMaxSize().background(MyMuColors.background).verticalScroll(rememberScrollState()).padding(22.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(Icons.Filled.HowToReg, null, tint = MyMuColors.primary, modifier = Modifier.padding(top = 28.dp).size(40.dp))
        Text("Sign in to MyMu", color = MyMuColors.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
        Text("Your MyMu username and password open $agentName's conversation.", color = MyMuColors.mutedText,
            fontSize = 13.sp, textAlign = TextAlign.Center)
        OutlinedTextField(origin, { origin = it }, label = { Text("MyMu host") }, singleLine = true, colors = colors,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth())
        OutlinedTextField(user, { user = it }, label = { Text("Username") }, singleLine = true, colors = colors,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next), modifier = Modifier.fillMaxWidth())
        OutlinedTextField(pass, { pass = it }, label = { Text("Password") }, singleLine = true, colors = colors,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { signIn() }), modifier = Modifier.fillMaxWidth())
        error?.let { Text(it, color = MyMuColors.danger, fontSize = 13.sp, modifier = Modifier.fillMaxWidth()) }
        Button(onClick = { signIn() }, enabled = !busy && user.isNotBlank() && pass.isNotEmpty(),
            colors = ButtonDefaults.buttonColors(containerColor = MyMuColors.primary),
            modifier = Modifier.fillMaxWidth()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (busy) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                Text(if (busy) "Signing in…" else "Sign in", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
