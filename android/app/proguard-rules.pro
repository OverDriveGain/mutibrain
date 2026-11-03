# Models are parsed by hand from org.json — no reflection, nothing to keep.

# The swarm WebView bridge: methods called from JS by name (window.MyAgentNative.post).
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keepattributes JavascriptInterface
