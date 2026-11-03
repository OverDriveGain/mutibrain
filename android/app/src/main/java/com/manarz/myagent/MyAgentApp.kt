package com.manarz.myagent

import android.app.Application
import com.manarz.myagent.capture.CaptureModule
import com.manarz.myagent.chat.ChatModule
import com.manarz.myagent.core.AppBuild
import com.manarz.myagent.core.AppContext
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Breadcrumbs
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.CrashReporter
import com.manarz.myagent.core.Notify
import com.manarz.myagent.core.ReportClient
import com.manarz.myagent.core.ServerConfig
import com.manarz.myagent.music.MusicModule
import com.manarz.myagent.push.PushModule
import com.manarz.myagent.voice.GadkVoice
import kotlin.concurrent.thread

class MyAgentApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppContext.set(this)
        Config.init(this)
        Breadcrumbs.init(this)
        ReportClient.init(this)
        CrashReporter.install(this)
        Notify.init(this)
        GadkVoice.init(this)
        // the modules register their seams (core.Music.host, push token, …)
        ChatModule.init(this)
        MusicModule.init(this)
        CaptureModule.init(this)
        PushModule.init(this)

        // If the previous run died, report what killed it; then say which build runs.
        CrashReporter.reportIfCrashed()
        Beacon.send(AppBuild.tag)
        ReportClient.flush()
        thread(name = "config-sync") { ServerConfig.sync() }
    }
}
