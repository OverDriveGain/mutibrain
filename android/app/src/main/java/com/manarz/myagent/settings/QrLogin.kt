package com.manarz.myagent.settings

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.mlkit.vision.MlKitAnalyzer
import androidx.camera.view.CameraController
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.manarz.myagent.core.ServerConfig
import com.manarz.myagent.core.Target
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The login check shared by the QR scanner, a pasted URL and a myagent:// link:
 * it must parse as …/voice?app=…&token=… AND the server must accept the token
 * (GET /config → 200). Bad/stale code = a clear message, nothing saved.
 */
suspend fun validateLogin(raw: String): Result<String> = withContext(Dispatchers.IO) {
    val u = Uri.parse(raw.trim())
    if (u.scheme !in setOf("http", "https") || u.getQueryParameter("app").isNullOrEmpty() ||
        u.getQueryParameter("token").isNullOrEmpty()) {
        return@withContext Result.failure(IllegalArgumentException("Not a voice login code (need …/voice?app=…&token=…)"))
    }
    if (ServerConfig.fetch(Target.from(raw.trim())) == null)
        return@withContext Result.failure(IllegalStateException("Server rejected this code (expired token?) — get a fresh QR from /admin"))
    Result.success(raw.trim())
}

/** Full-screen QR scanner (iOS QRLoginView). [onLogin] gets the validated URL. */
@Composable
fun QrLoginScreen(onLogin: (String) -> Unit, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var status by remember { mutableStateOf("Point the camera at the QR on your server's admin page") }
    var busy by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.CAMERA) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (granted) {
            val scanner: BarcodeScanner = remember {
                BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
            }
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { c ->
                    val view = PreviewView(c)
                    val cam = LifecycleCameraController(c)
                    val exec = ContextCompat.getMainExecutor(c)
                    cam.setImageAnalysisAnalyzer(exec, MlKitAnalyzer(listOf(scanner),
                        CameraController.COORDINATE_SYSTEM_VIEW_REFERENCED, exec) { result ->
                        val v = result.getValue(scanner)?.firstOrNull()?.rawValue ?: return@MlKitAnalyzer
                        if (busy) return@MlKitAnalyzer
                        busy = true
                        status = "Checking…"
                        scope.launch {
                            validateLogin(v).fold(
                                onSuccess = { onLogin(it) },
                                onFailure = { status = it.message ?: "Invalid code"; busy = false },
                            )
                        }
                    })
                    cam.bindToLifecycle(owner)
                    view.controller = cam
                    view
                },
            )
            Box(Modifier.align(Alignment.Center).size(240.dp).border(3.dp, Color.White.copy(alpha = 0.8f), RoundedCornerShape(24.dp)))
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Color.Black.copy(alpha = 0.6f)).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Text(if (granted) status else "Camera permission is needed to scan the login code",
                color = Color.White, textAlign = TextAlign.Center)
            TextButton(onClick = onClose) { Text("Cancel", color = Color.White) }
        }
    }
}
