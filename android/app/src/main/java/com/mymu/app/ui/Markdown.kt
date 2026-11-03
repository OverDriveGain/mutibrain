package com.mymu.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Lightweight markdown renderer in the spirit of the Claude / ChatGPT apps
 * (port of iOS MarkdownView): fenced code blocks get a real monospace card
 * (with copy + horizontal scroll); everything else renders as inline markdown
 * (bold/italic/inline-code/links/headings/lists) with whitespace preserved.
 */
sealed interface MdBlock {
    data class Txt(val text: String) : MdBlock
    data class Code(val language: String?, val code: String) : MdBlock
}

fun parseMarkdownBlocks(s: String): List<MdBlock> {
    val result = mutableListOf<MdBlock>()
    val lines = s.split("\n")
    val buffer = mutableListOf<String>()
    var i = 0

    fun flush() {
        val t = buffer.joinToString("\n").trim()
        if (t.isNotEmpty()) result.add(MdBlock.Txt(t))
        buffer.clear()
    }

    while (i < lines.size) {
        val line = lines[i]
        if (line.startsWith("```")) {
            flush()
            val lang = line.drop(3).trim()
            val code = mutableListOf<String>()
            i += 1
            while (i < lines.size && !lines[i].startsWith("```")) {
                code.add(lines[i]); i += 1
            }
            result.add(MdBlock.Code(lang.ifEmpty { null }, code.joinToString("\n")))
            i += 1 // skip closing fence (if present)
        } else {
            buffer.add(line); i += 1
        }
    }
    flush()
    return result
}

/** Inline markdown → AnnotatedString: headings, bold, italic, inline code,
 * links. Kept deliberately small — same scope as the iOS renderer. */
fun inlineMarkdown(text: String, baseColor: Color): AnnotatedString {
    val codeStyle = SpanStyle(
        fontFamily = FontFamily.Monospace,
        background = Color.White.copy(alpha = 0.08f),
        fontSize = 13.sp,
    )
    val linkStyle = TextLinkStyles(
        style = SpanStyle(color = MyMuColors.primary, textDecoration = TextDecoration.Underline))

    val pattern = Regex(
        "(`[^`\n]+`)" +                       // 1 inline code
        "|(\\*\\*[^*\n]+\\*\\*)" +            // 2 bold
        "|(\\*[^*\\s][^*\n]*\\*)" +           // 3 italic
        "|(\\[[^\\]\n]+\\]\\([^)\n]+\\))"     // 4 link
    )

    fun appendInline(b: AnnotatedString.Builder, line: String) {
        var idx = 0
        for (m in pattern.findAll(line)) {
            if (m.range.first > idx) b.append(line.substring(idx, m.range.first))
            val v = m.value
            when {
                v.startsWith("`") -> b.withStyle(codeStyle) { append(v.trim('`')) }
                v.startsWith("**") -> b.withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                    append(v.removeSurrounding("**"))
                }
                v.startsWith("[") -> {
                    val label = v.substringAfter('[').substringBefore(']')
                    val url = v.substringAfter('(').substringBefore(')')
                    b.withLink(LinkAnnotation.Url(url, linkStyle)) { append(label) }
                }
                else -> b.withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                    append(v.removeSurrounding("*"))
                }
            }
            idx = m.range.last + 1
        }
        if (idx < line.length) b.append(line.substring(idx))
    }

    return buildAnnotatedString {
        val lines = text.split("\n")
        lines.forEachIndexed { i, line ->
            val heading = line.takeWhile { it == '#' }.length
            if (heading in 1..6 && line.getOrNull(heading) == ' ') {
                withStyle(SpanStyle(
                    fontWeight = FontWeight.Bold,
                    fontSize = when (heading) { 1 -> 20.sp; 2 -> 18.sp; else -> 16.sp },
                    color = baseColor,
                )) { appendInline(this@buildAnnotatedString, line.drop(heading + 1)) }
            } else {
                appendInline(this, line)
            }
            if (i < lines.size - 1) append("\n")
        }
    }
}

@Composable
fun MarkdownView(text: String, color: Color = MyMuColors.text, modifier: Modifier = Modifier) {
    val blocks = remember(text) { parseMarkdownBlocks(text) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (block in blocks) {
            when (block) {
                is MdBlock.Code -> CodeBlock(block.language, block.code)
                is MdBlock.Txt -> {
                    val styled = remember(block.text, color) { inlineMarkdown(block.text, color) }
                    // Selectable: long-press picks a word, handles extend the
                    // range — the Compose counterpart of the iOS SelectableText
                    // (UITextView) partial-range copy in message bodies.
                    SelectionContainer {
                        Text(styled, color = color, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        }
    }
}

@Composable
fun CodeBlock(language: String?, code: String) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, MyMuColors.border, RoundedCornerShape(10.dp))
            .background(Color.Black.copy(alpha = 0.35f)),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .background(Color.White.copy(alpha = 0.03f))
                .padding(horizontal = 10.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(language ?: "code", color = MyMuColors.mutedText,
                style = MaterialTheme.typography.labelSmall)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = {
                clipboard.setText(AnnotatedString(code))
                copied = true
            }) {
                Text(if (copied) "Copied" else "Copy", color = MyMuColors.mutedText,
                    style = MaterialTheme.typography.labelSmall)
            }
        }
        // Selectable like the iOS code card (MarkdownView.swift:98).
        SelectionContainer {
            Text(
                code,
                color = MyMuColors.text,
                fontFamily = FontFamily.Monospace,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier
                    .horizontalScroll(rememberScrollState())
                    .padding(10.dp),
            )
        }
    }
}
