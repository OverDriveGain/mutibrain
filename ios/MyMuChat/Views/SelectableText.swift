import SwiftUI
import UIKit

/// Process-wide "is the user marking text right now?" signal, fed by every
/// SelectableText's delegate. The in-chat agent switcher must NOT raise while
/// a selection is live: distance/velocity thresholds alone can never separate
/// a fast selection-handle drag from a switch swipe — both are fast horizontal
/// drags over the transcript (Manar, 2026-09-29, hardening round 2).
@MainActor
final class TextSelectionMonitor {
    static let shared = TextSelectionMonitor()

    /// The row currently holding a non-empty selection. Weak: a LazyVStack
    /// recycling the row emits no delegate callback, and a dead reference must
    /// not block the switcher forever.
    private weak var active: UITextView?
    /// When the last selection ended — the tap/drag that dismisses a selection
    /// arrives right after and must not raise the switcher either.
    private var clearedAt: Date?

    var blocksSwitcher: Bool {
        if let active, active.selectedRange.length > 0 { return true }
        if let clearedAt, Date().timeIntervalSince(clearedAt) < 0.6 { return true }
        return false
    }

    func selectionChanged(_ textView: UITextView) {
        if textView.selectedRange.length > 0 {
            active = textView
        } else if active === textView {
            active = nil
            clearedAt = Date()
        }
    }
}

/// UITextView-backed text so the user can select WORDS and SENTENCES (loupe,
/// grab handles, partial-range copy) inside chat messages. SwiftUI's `Text` +
/// `.textSelection(.enabled)` only offers whole-block copy on iOS, which is why
/// this exists. Renders the same inline markdown the old Text path did (bold /
/// italic / inline code), preserves whitespace, detects links, and sizes itself
/// like a label (no internal scrolling).
struct SelectableText: UIViewRepresentable {
    let text: String
    var textColor: UIColor = UIColor(Theme.text)

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UITextViewDelegate {
        var lastText: String?
        func textViewDidChangeSelection(_ textView: UITextView) {
            // UIKit calls delegates on main; the isolation just isn't typed.
            MainActor.assumeIsolated {
                TextSelectionMonitor.shared.selectionChanged(textView)
            }
        }
    }

    /// Rendered-markdown cache shared across rows: LazyVStack derenders and
    /// recreates rows while scrolling, and re-parsing every message's markdown on
    /// each remount (plus on every SwiftUI update) was a main-thread hog in long
    /// chats.
    private static let renderCache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 400
        return c
    }()

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = [.link]
        tv.adjustsFontForContentSizeCategory = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Selection state feeds TextSelectionMonitor (switcher suppression).
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // SwiftUI calls this on EVERY graph update of the row — skip unless the
        // text actually changed, and reuse renders across row remounts.
        guard context.coordinator.lastText != text else { return }
        context.coordinator.lastText = text
        let key = text as NSString
        if let cached = SelectableText.renderCache.object(forKey: key) {
            tv.attributedText = cached
        } else {
            let rendered = SelectableText.render(text, color: textColor)
            SelectableText.renderCache.setObject(rendered, forKey: key)
            tv.attributedText = rendered
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    /// Inline markdown → NSAttributedString. AttributedString(markdown:) carries
    /// PRESENTATION INTENTS (strong/emphasis/code), not concrete fonts — SwiftUI
    /// Text resolves them but UIKit does not, so map them to UIFonts here.
    static func render(_ s: String, color: UIColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let attr = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)

        let base = UIFont.systemFont(ofSize: 17)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5

        let out = NSMutableAttributedString()
        for run in attr.runs {
            let piece = String(attr.characters[run.range])
            var font = base
            var fg = color
            var isCode = false

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { isCode = true }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if isCode {
                    font = UIFont.monospacedSystemFont(ofSize: 15.5, weight: traits.contains(.traitBold) ? .semibold : .regular)
                } else if !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: d, size: 17)
                }
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fg,
                .paragraphStyle: paragraph,
            ]
            if isCode {
                attrs[.backgroundColor] = UIColor.white.withAlphaComponent(0.08)
            }
            if let link = run.link {
                attrs[.link] = link
                fg = UIColor(Theme.primary)
                attrs[.foregroundColor] = fg
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}
