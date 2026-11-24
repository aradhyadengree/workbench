import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    let isDark: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        private var isHighlighting = false

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            guard !isHighlighting else { return }
            
            parent.document.buffer = editor.string
            highlight(editor: editor)
            updateCursorPosition(editor: editor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            updateCursorPosition(editor: editor)
        }

        func highlight(editor: NSTextView) {
            guard let textStorage = editor.textStorage else { return }
            isHighlighting = true
            let font = NSFont.monospacedSystemFont(ofSize: parent.document.fontSize, weight: .regular)
            SyntaxHighlighter.highlight(
                textStorage: textStorage,
                language: parent.document.language,
                isDark: parent.isDark,
                font: font
            )
            isHighlighting = false
        }

        func updateCursorPosition(editor: NSTextView) {
            let selectedRange = editor.selectedRange()
            let text = editor.string as NSString
            let location = min(selectedRange.location, text.length)
            
            var line = 1
            var col = 1
            var index = 0
            
            while index < location {
                if text.character(at: index) == 0x0A {
                    line += 1
                    col = 1
                } else {
                    col += 1
                }
                index += 1
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.parent.document.cursorLine = line
                self.parent.document.cursorColumn = col
                self.parent.document.ruler?.activeLine = line
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = document.editor
        guard let editor = scroll.documentView as? NSTextView else { return scroll }

        let colors = WorkbenchTheme.SyntaxColors.current(isDark: isDark)
        let font = NSFont.monospacedSystemFont(ofSize: document.fontSize, weight: .regular)

        editor.font = font
        editor.isRichText = true
        editor.importsGraphics = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.usesFindBar = true
        editor.allowsUndo = true
        editor.backgroundColor = colors.background
        editor.textColor = colors.text
        editor.insertionPointColor = colors.activeLineGutterText
        editor.textContainerInset = NSSize(width: 10, height: 8)

        // Setup Line Number Ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let ruler = LineNumberRulerView(textView: editor)
        ruler.isDarkMode = isDark
        scroll.verticalRulerView = ruler
        document.ruler = ruler

        if editor.string != document.buffer {
            editor.string = document.buffer
        }

        editor.delegate = context.coordinator
        context.coordinator.highlight(editor: editor)

        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = view.documentView as? NSTextView else { return }

        let colors = WorkbenchTheme.SyntaxColors.current(isDark: isDark)
        editor.backgroundColor = colors.background
        editor.insertionPointColor = colors.activeLineGutterText
        document.ruler?.isDarkMode = isDark

        // Update font if changed
        let expectedFont = NSFont.monospacedSystemFont(ofSize: document.fontSize, weight: .regular)
        if editor.font?.pointSize != document.fontSize {
            editor.font = expectedFont
            context.coordinator.highlight(editor: editor)
        }

        if editor.string != document.buffer {
            editor.string = document.buffer
            context.coordinator.highlight(editor: editor)
            context.coordinator.updateCursorPosition(editor: editor)
        }
    }
}
