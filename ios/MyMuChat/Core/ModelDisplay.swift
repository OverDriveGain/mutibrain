import Foundation

/// Short display names for model identifiers.
///
/// Raw ids are UI-hostile ("claude-sonnet-5-20260203", "sonnet[1m]") and the
/// catalogue's "default" says nothing. Format the shapes we KNOW; anything we
/// can't confidently parse is shown exactly as-is — a wrong pretty name is
/// worse than an ugly true one.
enum ModelDisplay {
    /// "claude-sonnet-5-20260203" → "Sonnet 5" · "sonnet[1m]" → "Sonnet 1M"
    /// "claude-opus-4-8" → "Opus 4.8" · "default" → "Auto" · unknown → as-is.
    static func short(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty else { return original }
        if original.caseInsensitiveCompare("default") == .orderedSame { return "Auto" }

        var v = original.lowercased()
        var oneMillion = false
        if v.hasSuffix("[1m]") { oneMillion = true; v = String(v.dropLast(4)) }
        if v.hasPrefix("claude-") { v = String(v.dropFirst("claude-".count)) }
        // Trailing release-date stamp carries no meaning for a person.
        v = v.replacingOccurrences(of: #"-20\d{6,8}$"#, with: "", options: .regularExpression)

        let families = ["fable", "mythos", "opus", "sonnet", "haiku"]
        guard let family = families.first(where: { v == $0 || v.hasPrefix($0 + "-") }) else {
            return original
        }
        var out = family.capitalized
        let rest = v.dropFirst(family.count).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if !rest.isEmpty, rest.allSatisfy({ $0.isNumber || $0 == "-" }) {
            out += " " + rest.replacingOccurrences(of: "-", with: ".")
        } else if !rest.isEmpty {
            return original  // e.g. "opus-plan" — a shape we don't know; keep truth
        }
        return oneMillion ? out + " 1M" : out
    }

    /// Shortcut form for the title-bar strip — tight, lowercase, glued:
    /// "claude-opus-4-7" → "opus4.7" · "opus[1m]" → "opus1m" ·
    /// "deepseek-v4-pro" → "ds-v4-pro" · "gpt-5.2-sol" → "sol5.2" ·
    /// "default" → "auto". Shapes we can't confidently parse pass through
    /// verbatim (lowercased only when already short, untouched otherwise) —
    /// the strip is small, but a wrong name there is still a wrong name.
    static func compact(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty else { return original }
        if original.caseInsensitiveCompare("default") == .orderedSame { return "auto" }

        var v = original.lowercased()
        var oneMillion = false
        if v.hasSuffix("[1m]") { oneMillion = true; v = String(v.dropLast(4)) }
        // Vendor paths ("openrouter/deepseek/…") — the last segment is the model.
        if let last = v.split(separator: "/").last { v = String(last) }
        if v.hasPrefix("claude-") { v = String(v.dropFirst("claude-".count)) }
        v = v.replacingOccurrences(of: #"-20\d{6,8}$"#, with: "", options: .regularExpression)

        // OpenAI codex naming: gpt-<version>-<variant> → variant+version.
        if let m = v.range(of: #"^gpt-([\d.]+)-([a-z]+)$"#, options: .regularExpression) {
            let parts = String(v[m]).dropFirst(4).split(separator: "-")
            if parts.count == 2 { return "\(parts[1])\(parts[0])" }
        }
        // DeepSeek keeps its qualifiers, family abbreviated: ds-v4-pro.
        if v == "deepseek" || v.hasPrefix("deepseek-") {
            return "ds" + v.dropFirst("deepseek".count)
        }
        // Claude families: glue family+version, dashes in the version → dots.
        let families = ["fable", "mythos", "opus", "sonnet", "haiku"]
        if let family = families.first(where: { v == $0 || v.hasPrefix($0 + "-") }) {
            let rest = v.dropFirst(family.count).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if rest.isEmpty { return oneMillion ? family + "1m" : family }
            if rest.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "." }) {
                let ver = rest.replacingOccurrences(of: "-", with: ".")
                return family + ver + (oneMillion ? "-1m" : "")
            }
        }
        return original
    }
}
