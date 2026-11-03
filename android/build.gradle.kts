// Top-level build file — plugin versions only. The single app module is :app.
plugins {
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.21" apply false
    // FCM config plugin — on the classpath here, applied by :app ONLY when
    // app/google-services.json exists (the build needs no Firebase project).
    id("com.google.gms.google-services") version "4.4.2" apply false
}
