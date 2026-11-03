package com.mymu.app.core

/**
 * Short display names for model identifiers. (1:1 port of iOS ModelDisplay.)
 *
 * Raw ids are UI-hostile ("claude-sonnet-5-20260203", "sonnet[1m]") and the
 * catalogue's "default" says nothing. Format the shapes we KNOW; anything we
 * can't confidently parse is shown exactly as-is — a wrong pretty name is
 * worse than an ugly true one.
 */
object ModelDisplay {
    private val families = listOf("fable", "mythos", "opus", "sonnet", "haiku")
    private val dateStamp = Regex("-20\\d{6,8}$")

    /** "claude-sonnet-5-20260203" → "Sonnet 5" · "sonnet[1m]" → "Sonnet 1M"
     * · "claude-opus-4-8" → "Opus 4.8" · "default" → "Auto" · unknown → as-is. */
    fun short(raw: String): String {
        val original = raw.trim()
        if (original.isEmpty()) return original
        if (original.equals("default", ignoreCase = true)) return "Auto"

        var v = original.lowercase()
        var oneMillion = false
        if (v.endsWith("[1m]")) { oneMillion = true; v = v.dropLast(4) }
        if (v.startsWith("claude-")) v = v.removePrefix("claude-")
        v = v.replace(dateStamp, "")

        val family = families.firstOrNull { v == it || v.startsWith("$it-") } ?: return original
        var out = family.replaceFirstChar { it.uppercase() }
        val rest = v.removePrefix(family).trim('-')
        if (rest.isNotEmpty() && rest.all { it.isDigit() || it == '-' }) {
            out += " " + rest.replace("-", ".")
        } else if (rest.isNotEmpty()) {
            return original  // e.g. "opus-plan" — a shape we don't know; keep truth
        }
        return if (oneMillion) "$out 1M" else out
    }

    /** Shortcut form for the title-bar strip — tight, lowercase, glued:
     * "claude-opus-4-7" → "opus4.7" · "deepseek-v4-pro" → "ds-v4-pro" ·
     * "gpt-5.2-sol" → "sol5.2" · "default" → "auto". */
    fun compact(raw: String): String {
        val original = raw.trim()
        if (original.isEmpty()) return original
        if (original.equals("default", ignoreCase = true)) return "auto"

        var v = original.lowercase()
        var oneMillion = false
        if (v.endsWith("[1m]")) { oneMillion = true; v = v.dropLast(4) }
        // Vendor paths ("openrouter/deepseek/…") — the last segment is the model.
        v = v.substringAfterLast('/')
        if (v.startsWith("claude-")) v = v.removePrefix("claude-")
        v = v.replace(dateStamp, "")

        // OpenAI codex naming: gpt-<version>-<variant> → variant+version.
        Regex("^gpt-([\\d.]+)-([a-z]+)$").find(v)?.let { m ->
            return m.groupValues[2] + m.groupValues[1]
        }
        // DeepSeek keeps its qualifiers, family abbreviated: ds-v4-pro.
        if (v == "deepseek" || v.startsWith("deepseek-")) {
            return "ds" + v.removePrefix("deepseek")
        }
        // Claude families: glue family+version, dashes in the version → dots.
        families.firstOrNull { v == it || v.startsWith("$it-") }?.let { family ->
            val rest = v.removePrefix(family).trim('-')
            if (rest.isEmpty()) return if (oneMillion) family + "1m" else family
            if (rest.all { it.isDigit() || it == '-' || it == '.' }) {
                val ver = rest.replace("-", ".")
                return family + ver + (if (oneMillion) "-1m" else "")
            }
        }
        return original
    }
}
