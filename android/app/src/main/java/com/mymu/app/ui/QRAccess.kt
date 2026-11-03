package com.mymu.app.ui

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.ImageAnalysis
import androidx.camera.mlkit.vision.MlKitAnalyzer
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.json.JSONObject
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * QR-based access hand-off (Manar, 2026-09-19): one device shows a QR that
 * encodes server + username (password optional, typed in at share time —
 * the app never has it stored); another device scans it and lands on a
 * prefilled sign-in. The payload is a `mymu://login?...` URL — so the plain
 * phone CAMERA also works: the system camera / Lens offers "Open with MyMu"
 * (the VIEW intent filter on MainActivity) and the app opens with the fields
 * entered (Manar's actual flow; the first JSON payload only worked from the
 * in-app scanner and the camera sent it to the browser). Legacy JSON
 * payloads and bare server URLs still parse. (1:1 port of iOS
 * Views/QRAccess.swift — the type lives beside its sheets there too.)
 */
data class AccessPayload(
    val origin: String,
    val username: String? = null,
    val password: String? = null,
) {
    /** The QR/link form: mymu://login?origin=…&username=…[&password=…] */
    val qrString: String
        get() {
            val items = mutableListOf("origin=" + encode(origin))
            username?.let { items.add("username=" + encode(it)) }
            password?.let { items.add("password=" + encode(it)) }
            return "mymu://login?" + items.joinToString("&")
        }

    companion object {
        /**
         * mymu:// links first (QRs + the VIEW intent share this parser), then
         * legacy JSON with the marker, then bare server addresses (people QR
         * their server URL more often than one thinks).
         */
        fun parse(raw: String): AccessPayload? {
            val s = raw.trim()
            if (s.lowercase().startsWith("mymu://")) {
                val q = queryItems(s)
                val origin = q["origin"]
                if (origin.isNullOrEmpty()) return null
                return AccessPayload(origin, q["username"], q["password"])
            }
            try {
                val o = JSONObject(s)
                // Codable on iOS requires `mymu` AND `origin`; the rest is optional.
                if (o.optInt("mymu") == 1 && o.has("origin") && !o.isNull("origin")) {
                    return AccessPayload(o.getString("origin"), o.str("username"), o.str("password"))
                }
            } catch (_: Exception) {}
            if (s.isEmpty() || s.contains("{") || s.contains(" ")) return null
            return AccessPayload(s)
        }

        private fun JSONObject.str(key: String): String? =
            if (has(key) && !isNull(key)) getString(key) else null

        /**
         * Query pairs, first occurrence wins, keys without `=` dropped —
         * URLComponents.queryItems semantics. Percent-decoding only: a literal
         * `+` stays a `+` (URLComponents never reads it as a space, and a
         * password may well contain one), which is why URLDecoder's
         * form-encoding rule is sidestepped.
         */
        private fun queryItems(url: String): Map<String, String> {
            val query = url.substringAfter('?', "").substringBefore('#')
            val out = LinkedHashMap<String, String>()
            for (pair in query.split('&')) {
                val i = pair.indexOf('=')
                if (i < 0) continue
                val k = decode(pair.substring(0, i))
                if (k !in out) out[k] = decode(pair.substring(i + 1))
            }
            return out
        }

        private fun decode(s: String): String = try {
            URLDecoder.decode(s.replace("+", "%2B"), "UTF-8")
        } catch (_: Exception) { s }

        /** RFC 3986 percent-encoding (what URLComponents emits), built on
         * URLEncoder's form encoding with its three divergences undone. */
        private fun encode(s: String): String =
            URLEncoder.encode(s, "UTF-8").replace("+", "%20").replace("*", "%2A").replace("%7E", "~")
    }
}

// MARK: - Share (generate)

/**
 * Sheet showing the access QR for an account. Origin + username come from
 * the ACTIVE account; the password is typed here if (and only if) the QR
 * should carry a full sign-in — it lives in this sheet's state and nowhere
 * else.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccessQRSheet(origin: String, username: String, onDismiss: () -> Unit) {
    var password by remember { mutableStateOf("") }
    val payload = AccessPayload(origin, username, password.ifEmpty { null })
    val qr = remember(payload.qrString) { qrBitmap(payload.qrString) }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MyMuColors.background) {
        Column(
            Modifier.fillMaxWidth().imePadding().padding(horizontal = 24.dp).padding(bottom = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Access QR", color = MyMuColors.text, style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Done", color = MyMuColors.primary) }
            }
            Spacer(Modifier.height(18.dp))
            if (qr != null) {
                // White card = the quiet zone a scanner needs around the modules.
                Box(Modifier.background(Color.White, RoundedCornerShape(16.dp)).padding(14.dp)) {
                    Image(
                        bitmap = qr.asImageBitmap(),
                        contentDescription = "Access QR for $username",
                        // 1 px per module upscaled with no filtering — iOS
                        // `.interpolation(.none)`; a bilinear blur is what
                        // makes phone cameras miss small QRs.
                        filterQuality = FilterQuality.None,
                        modifier = Modifier.size(240.dp),
                    )
                }
            }
            Spacer(Modifier.height(18.dp))
            Text(username, color = MyMuColors.text, style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(3.dp))
            Text(origin, color = MyMuColors.mutedText, style = MaterialTheme.typography.labelMedium)
            Spacer(Modifier.height(18.dp))
            // Password stays OUT of the QR until typed — sharing just
            // server+user is the safe default; the full sign-in QR is an
            // explicit act.
            LoginField("Password (optional — include to sign in on scan)", password, { password = it },
                Icons.Outlined.Lock, KeyboardType.Password, secure = true)
            Spacer(Modifier.height(12.dp))
            Text(
                if (password.isEmpty())
                    "Scan with the phone camera — MyMu opens with server and username entered; the password is typed there."
                else
                    "This QR now signs in directly — anyone who scans it gets access.",
                color = if (password.isEmpty()) MyMuColors.mutedText else MyMuColors.danger,
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * Crisp ZXing QR at 1 px per module (CoreImage's generator on iOS, scaled
 * 12× there — here the Image upscales with FilterQuality.None instead).
 * Correction level M like iOS; margin 2 modules, the white card adds the
 * rest of the quiet zone. Null when the text can't be encoded.
 */
private fun qrBitmap(text: String): Bitmap? = try {
    val hints = mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2)
    // Width/height 0 → ZXing emits the matrix at its natural module size.
    val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, hints)
    val w = m.width
    val h = m.height
    val px = IntArray(w * h) { i -> if (m.get(i % w, i / w)) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
    Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
} catch (_: Exception) { null }

// MARK: - Scan

/**
 * Camera QR scanner for the login screen. CameraX's LifecycleCameraController
 * + ML Kit through MlKitAnalyzer — no Camera2 plumbing (VisionKit's
 * DataScanner on iOS); first recognized QR wins and the sheet dismisses.
 * Asks for CAMERA on open (Accompanist isn't in the project; the plain
 * RequestPermission contract is enough for one permission).
 */
@Composable
fun QRScanSheet(onScan: (AccessPayload) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val hasCamera = remember {
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
    }
    var granted by remember {
        mutableStateOf(context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    // false while the system prompt is up — the fallback copy must not flash
    // behind it before the user has answered.
    var answered by remember { mutableStateOf(granted || !hasCamera) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok
        answered = true
    }
    LaunchedEffect(Unit) { if (hasCamera && !granted) permission.launch(Manifest.permission.CAMERA) }
    var rejected by remember { mutableStateOf(false) }
    // The analyzer keeps reporting the same code every frame; one hit is all
    // the hand-off takes.
    var handled by remember { mutableStateOf(false) }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(MyMuColors.background)) {
            Row(
                Modifier.fillMaxWidth().statusBarsPadding().padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Scan access QR", color = MyMuColors.text, style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Cancel", color = MyMuColors.primary) }
            }
            Box(Modifier.fillMaxSize()) {
                when {
                    hasCamera && granted -> {
                        CameraQRPreview(
                            onRaw = { raw ->
                                if (handled) return@CameraQRPreview
                                val payload = AccessPayload.parse(raw)
                                if (payload != null) {
                                    handled = true
                                    onDismiss()
                                    onScan(payload)
                                } else {
                                    rejected = true
                                }
                            },
                            modifier = Modifier.fillMaxSize(),
                        )
                        Text(
                            if (rejected) "Not a MyMu access code — keep scanning."
                            else "Point at an access QR from another MyMu.",
                            color = if (rejected) MyMuColors.danger else MyMuColors.mutedText,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .padding(bottom = 24.dp)
                                .background(MyMuColors.background.copy(alpha = 0.85f), CircleShape)
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        )
                    }
                    !answered -> {} // system permission prompt is up
                    else -> {
                        // Emulator without a camera, device restriction, or
                        // permission denied.
                        Column(
                            Modifier.fillMaxSize().padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Icon(Icons.Outlined.CameraAlt, contentDescription = null,
                                tint = MyMuColors.mutedText, modifier = Modifier.size(28.dp))
                            Spacer(Modifier.height(10.dp))
                            Text(
                                "Camera scanning isn't available on this device.\nCheck camera access for MyMu in Settings.",
                                color = MyMuColors.mutedText, style = MaterialTheme.typography.bodySmall,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Live preview bound to the composition's lifecycle, with ML Kit's QR-only
 * detector attached as the frame analyzer. The raw string of every detected
 * code is handed up; the caller decides what counts.
 */
@Composable
private fun CameraQRPreview(onRaw: (String) -> Unit, modifier: Modifier) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val latestOnRaw by rememberUpdatedState(onRaw)
    val scanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
    }
    DisposableEffect(Unit) { onDispose { scanner.close() } }
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val executor = ContextCompat.getMainExecutor(ctx)
            PreviewView(ctx).apply {
                val controller = LifecycleCameraController(ctx)
                controller.setImageAnalysisAnalyzer(
                    executor,
                    MlKitAnalyzer(listOf(scanner), ImageAnalysis.COORDINATE_SYSTEM_ORIGINAL, executor) { result ->
                        result.getValue(scanner)?.firstOrNull()?.rawValue?.let { latestOnRaw(it) }
                    },
                )
                controller.bindToLifecycle(lifecycleOwner)
                this.controller = controller
            }
        },
        onRelease = { view ->
            (view.controller as? LifecycleCameraController)?.unbind()
            view.controller = null
        },
    )
}
