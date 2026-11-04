package com.manarz.myagent.home

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.view.HapticFeedbackConstants
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.manarz.myagent.core.AppEvent
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Events
import com.manarz.myagent.core.Music
import com.manarz.myagent.core.Net
import com.manarz.myagent.core.Target
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import java.util.Locale

/**
 * The swarm/critter = the server's embed page (static/critter/embed.html) in a
 * WebView — the Android port of iOS CritterView/CritterController.
 *
 * Native → page: `window.critter.setState/setLevel/perform/setStage/
 * setCapabilities/setPending` via evaluateJavascript.
 * Page → native: the embed talks to its host through the iOS bridge names
 * (`window.webkit.messageHandlers.<name>.postMessage`). We install that exact
 * object at DOCUMENT START, forwarding to a @JavascriptInterface — so the one
 * embed serves both apps unchanged (it decides "am I in the app?" by probing
 * those handlers at module load, hence document-start, not onPageFinished).
 */
class CritterController {
    var web: WebView? = null
        internal set
    private val main = Handler(Looper.getMainLooper())
    private var pendingState = "idle"
    private var lastLevelAt = 0L
    private var lastLevel = -1f
    private var stageJS = ""
    private var lastStageJS = ""
    private var stageInFlight = false
    private var feedTimer: Runnable? = null
    private var feed: Target? = null
    /** Sets --host-sat (status-bar inset) on the page; see makeCritterWebView. */
    internal var insetJs = ""

    private fun js(s: String, cb: ((String?) -> Unit)? = null) =
        main.post { web?.evaluateJavascript(s) { r -> cb?.invoke(r) } }

    fun setState(state: String) { pendingState = state; apply() }
    internal fun apply() = js("window.critter && window.critter.setState('$pendingState')")

    fun perform(move: String, duration: Double? = null) {
        val opts = if (duration != null && duration > 0) String.format(Locale.US, ", { duration: %.2f }", duration) else ""
        js("window.critter && window.critter.perform && window.critter.perform('$move'$opts)")
    }

    /** ≤30 Hz and only on a visible change — every call is a JS round-trip. */
    fun setLevel(v: Float) {
        val now = System.currentTimeMillis()
        if (now - lastLevelAt < 33 || !(kotlin.math.abs(v - lastLevel) > 0.015f || (v == 0f && lastLevel != 0f))) return
        lastLevelAt = now; lastLevel = v
        js(String.format(Locale.US, "window.critter && window.critter.setLevel && window.critter.setLevel(%.3f)", v))
    }

    /** Drawer composition: coalesced — at most one stage call in flight. */
    fun setStage(shift: Float, scale: Float, inset: Float, dragging: Boolean) {
        stageJS = String.format(Locale.US,
            "window.critter && window.critter.setStage && window.critter.setStage({shift:%.1f,scale:%.3f,inset:%.0f,dragging:%s})",
            shift, scale, inset, dragging)
        if (!stageInFlight) flushStage()
    }

    private fun flushStage() {
        if (stageJS.isEmpty()) return
        val s = stageJS; lastStageJS = s; stageJS = ""; stageInFlight = true
        js(s) { stageInFlight = false; if (stageJS.isNotEmpty()) flushStage() }
    }

    internal fun reassertStage() { if (stageJS.isEmpty()) stageJS = lastStageJS; stageInFlight = false; flushStage() }

    /** Wait for the page's module script to publish window.critter (it's async after load). */
    internal fun whenReady(attempts: Int = 50, fn: () -> Unit) {
        js("!!(window.critter && window.critter.setState)") { r ->
            if (r == "true") fn() else if (attempts > 1) main.postDelayed({ whenReady(attempts - 1, fn) }, 120)
        }
    }

    fun resync() { apply(); reassertStage(); pushCapabilities(); refreshPending() }

    // ---- server feeds the page shows: hand-off chips (/pending), hint list (/capabilities)
    fun startFeeds(t: Target) {
        if (!t.hasToken) return
        feed = t
        pushCapabilities(); refreshPending()
        feedTimer?.let { main.removeCallbacks(it) }
        var tick = 0
        val r = object : Runnable {
            override fun run() {
                refreshPending()
                if (++tick % 12 == 0) pushCapabilities()
                main.postDelayed(this, 5000)
            }
        }
        feedTimer = r
        main.postDelayed(r, 5000)
    }

    fun stopFeeds() { feedTimer?.let { main.removeCallbacks(it) }; feedTimer = null }

    internal fun pushCapabilities() = pushFeed("capabilities", "capabilities", "setCapabilities")
    fun refreshPending() = pushFeed("pending", "pending", "setPending")

    private fun pushFeed(path: String, key: String, fn: String) {
        val t = feed ?: return
        Net.http.newCall(Request.Builder().url(t.url("/$path")).build()).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {}
            override fun onResponse(call: Call, response: Response) {
                val body = response.use { it.body?.string() } ?: return
                val arr = runCatching { JSONObject(body).opt(key) }.getOrNull() ?: return
                val json = arr.toString().replace(" ", " ").replace(" ", " ")
                js("window.critter && window.critter.$fn && window.critter.$fn($json)")
            }
        })
    }
}

/** The bridge object the document-start shim forwards to. */
private class NativeBridge(private val ctx: Context, private val web: () -> WebView?) {
    @JavascriptInterface
    fun post(name: String, body: String?) {
        val obj = runCatching { if (body.isNullOrEmpty() || body == "null") null else JSONObject(body) }.getOrNull()
        when (name) {
            // the home's Screen button: straight to the capture consent (`present`);
            // anything else opens the full Screenpipe page
            "mymuBroadcast" -> Events.post(AppEvent.ShowScreenpipe(present = obj?.optString("action") == "present"))
            "mymuCompose" -> Events.post(AppEvent.Composing(obj?.optBoolean("open") ?: false))
            "mymuMusic" -> {
                val action = obj?.optString("action") ?: return
                val songs = obj.optJSONArray("songs")
                if (action == "play" && songs != null && songs.length() > 0) {
                    Beacon.send("massam-play-${songs.length()}")
                    Music.host?.play(songs, obj.optInt("startAt", 0))
                } else Music.host?.control(action)
            }
            "mymuHaptic" -> Handler(Looper.getMainLooper()).post {
                web()?.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            }
            "mymuClipboard" -> {
                // the page posts a bare string; the shim wraps non-objects as {value}
                val text = obj?.optString("value") ?: body ?: return
                val cm = ctx.getSystemService(ClipboardManager::class.java)
                cm.setPrimaryClip(ClipData.newPlainText("MyMu", text))
            }
        }
    }
}

private val SHIM = """
(function(){
  if (window.__myagentShim) return; window.__myagentShim = true;
  function h(n){ return { postMessage: function(b){
    var o = (b !== null && typeof b === 'object') ? b : { value: b };
    try { MyAgentNative.post(n, JSON.stringify(o)); } catch(e) {}
  } }; }
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = {
    mymuBroadcast: h('mymuBroadcast'), mymuCompose: h('mymuCompose'), mymuMusic: h('mymuMusic'),
    mymuHaptic: h('mymuHaptic'), mymuClipboard: h('mymuClipboard')
  };
})();
""".trimIndent()

/** A file chooser request from the page (the Files / ingest boxes). */
var pendingFileChooser: ValueCallback<Array<Uri>>? = null
var launchFileChooser: ((Intent) -> Unit)? = null

@SuppressLint("SetJavaScriptEnabled")
fun makeCritterWebView(ctx: Context, ctl: CritterController, fragment: String): WebView {
    val web = WebView(ctx)
    // MATCH_PARENT, not AndroidView's default WRAP_CONTENT: a wrap_content
    // WebView makes Chromium resolve 100vh/dvh to 0, which collapsed every
    // massam box to a 1px line (2026-11-03). The embed also self-heals (--app-h).
    web.layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    web.setBackgroundColor(Color.rgb(5, 6, 8))        // #050608, under the swarm's edges
    web.isVerticalScrollBarEnabled = false
    web.isHorizontalScrollBarEnabled = false
    web.overScrollMode = WebView.OVER_SCROLL_NEVER
    with(web.settings) {
        javaScriptEnabled = true
        domStorageEnabled = true                       // localStorage: last critter + panel (bad-connection fallback)
        mediaPlaybackRequiresUserGesture = false
        cacheMode = WebSettings.LOAD_DEFAULT
        setSupportMultipleWindows(true)                // target=_blank → onCreateWindow
    }
    web.addJavascriptInterface(NativeBridge(ctx.applicationContext) { ctl.web }, "MyAgentNative")
    // Android WebViews report env(safe-area-inset-top) as 0 even edge-to-edge; the embed
    // takes the host's status-bar inset from --host-sat instead (iOS leaves it unset).
    val sat = ctx.resources.getIdentifier("status_bar_height", "dimen", "android").let { id ->
        if (id > 0) (ctx.resources.getDimensionPixelSize(id) / ctx.resources.displayMetrics.density).toInt() else 32
    }
    val insetJs = "document.documentElement.style.setProperty('--host-sat','${sat}px');"
    if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
        WebViewCompat.addDocumentStartJavaScript(web, SHIM + "\n" + insetJs, setOf("*"))
    }
    ctl.insetJs = insetJs
    web.webViewClient = object : WebViewClient() {
        override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
            // old WebView without document-start scripts: best effort, early as we can
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) view.evaluateJavascript(SHIM + ctl.insetJs, null)
        }
        override fun onPageFinished(view: WebView, url: String?) {
            if (ctl.insetJs.isNotEmpty()) view.evaluateJavascript(ctl.insetJs, null)
            ctl.whenReady {
                ctl.apply(); ctl.pushCapabilities(); ctl.refreshPending(); ctl.reassertStage()
            }
            Handler(Looper.getMainLooper()).postDelayed({ ctl.reassertStage() }, 2500)
            Handler(Looper.getMainLooper()).postDelayed({
                view.evaluateJavascript("window.critter && window.critter.moves ? 'moves:' + window.critter.moves.join('+') : 'OLD-EMBED'") {
                    Beacon.send("embed-" + (it?.trim('"') ?: "no-critter-api"))
                }
            }, 3000)
        }
        override fun shouldOverrideUrlLoading(view: WebView, req: WebResourceRequest): Boolean {
            // stay on the embed; any real navigation (links in boxes) → the browser
            val u = req.url
            if (u.path?.startsWith("/static/critter/") == true) return false
            runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, u).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            return true
        }
        /** The renderer was killed to reclaim memory: reload instead of a frozen swarm. */
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            Beacon.send("embed-process-terminated")
            Handler(Looper.getMainLooper()).post { view.reload() }
            return true
        }
    }
    web.webChromeClient = object : WebChromeClient() {
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            // downloads / files open target=_blank: hand the URL to the browser
            val tmp = WebView(ctx)
            tmp.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest): Boolean {
                    runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, r.url).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                    v.destroy(); return true
                }
            }
            (resultMsg.obj as WebView.WebViewTransport).webView = tmp
            resultMsg.sendToTarget()
            return true
        }
        override fun onShowFileChooser(view: WebView, cb: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
            pendingFileChooser?.onReceiveValue(null)
            pendingFileChooser = cb
            val launch = launchFileChooser ?: run { cb.onReceiveValue(null); pendingFileChooser = null; return false }
            launch(params.createIntent().putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.mode == FileChooserParams.MODE_OPEN_MULTIPLE))
            return true
        }
    }
    ctl.web = web
    val t = Target.current()
    // identity in the URL FRAGMENT (never sent to the server / logs)
    val url = "${t.origin}/static/critter/embed.html#$fragment"
    web.loadUrl(url, mapOf("Cache-Control" to "no-cache"))
    return web
}

/** The fragment the home embed gets: subscriber identity, no web composer (the app has its own chat). */
fun homeFragment(t: Target = Target.current()): String =
    if (t.hasToken) "app=${t.app}&token=${t.token}&nochat=1" else "nochat=1"
