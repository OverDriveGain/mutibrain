package com.mymu.app.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit

/**
 * Short human label for a message timestamp — the same buckets the web
 * client's `formatMessageTimestamp` uses, so both products narrate time
 * identically: "Just now", "12 mins ago", "3 hours ago", "Yesterday 14:32",
 * "Mon 09:10", and a full date once a week has passed.
 * (1:1 port of iOS Core/MessageTime.swift.)
 */
object MessageTime {
    private val timeFmt = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
    private val weekdayFmt = DateTimeFormatter.ofPattern("EEE")
    private val dateFmt = DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT)

    fun label(iso: String?, nowMs: Long = System.currentTimeMillis()): String? {
        iso ?: return null
        val ms = RelayClient.parseIso(iso) ?: return null
        val elapsed = (nowMs - ms) / 1000
        // Clock-skew / same-minute sends land here too.
        if (elapsed < 60) return "Just now"

        val zone = ZoneId.systemDefault()
        val date = Instant.ofEpochMilli(ms).atZone(zone)
        val now = Instant.ofEpochMilli(nowMs).atZone(zone)
        val time = timeFmt.format(date)
        val dayDiff = ChronoUnit.DAYS.between(date.toLocalDate(), now.toLocalDate())
        if (dayDiff <= 0) {
            val mins = elapsed / 60
            if (mins < 60) return if (mins == 1L) "1 min ago" else "$mins mins ago"
            val hours = elapsed / 3600
            return if (hours == 1L) "1 hour ago" else "$hours hours ago"
        }
        if (dayDiff == 1L) return "Yesterday $time"
        if (dayDiff < 7) return "${weekdayFmt.format(date)} $time"
        return "${dateFmt.format(date)} $time"
    }
}
