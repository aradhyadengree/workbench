import AppKit

final class LineNumberRulerView: NSRulerView {
    var activeLine: Int = 1 {
        didSet {
            if oldValue != activeLine {
                needsDisplay = true
            }
        }
    }
    
    var isDarkMode: Bool = true {
        didSet {
            if oldValue != isDarkMode {
                needsDisplay = true
            }
        }
    }

    private var lineCount: Int = 1

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 42
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    @objc private func viewDidScroll(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let colors = WorkbenchTheme.SyntaxColors.current(isDark: isDarkMode)
        
        // Draw gutter background
        colors.gutterBackground.setFill()
        rect.fill()

        // Draw 1px right border for crisp separation
        let borderRect = NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height)
        (isDarkMode ? WorkbenchTheme.SyntaxColors.dark.gutterText.withAlphaComponent(0.2) :
                      WorkbenchTheme.SyntaxColors.light.gutterText.withAlphaComponent(0.3)).setFill()
        borderRect.fill()

        let visibleRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let text = textView.string as NSString
        let textLength = text.length
        
        guard textLength > 0 else {
            drawLineNumber(1, atY: visibleRect.minY + textView.textContainerInset.height, isActive: true, colors: colors)
            return
        }

        let startCharIndex = layoutManager.characterIndexForGlyph(at: visibleGlyphRange.location)
        
        // Compute line number at startCharIndex
        var lineNumber = 1
        var index = 0
        while index < startCharIndex && index < textLength {
            if text.character(at: index) == 0x0A { // \n
                lineNumber += 1
            }
            index += 1
        }

        var glyphIndex = visibleGlyphRange.location
        let maxGlyph = NSMaxRange(visibleGlyphRange)

        while glyphIndex < maxGlyph {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lineGlyphRange.location, effectiveRange: nil)
            let y = lineRect.origin.y + textView.textContainerInset.height - visibleRect.origin.y

            let isActive = (lineNumber == activeLine)
            
            // Draw active line gutter highlight
            if isActive {
                let activeGutterRect = NSRect(x: 0, y: y, width: bounds.width - 1, height: lineRect.height)
                colors.activeLineBackground.setFill()
                activeGutterRect.fill()
            }

            drawLineNumber(lineNumber, atY: y, isActive: isActive, colors: colors)

            lineNumber += 1
            glyphIndex = NSMaxRange(lineGlyphRange)
        }

        // Adjust ruler width based on number of digits
        let estimatedDigits = max(2, String(lineNumber).count)
        let neededThickness = CGFloat(estimatedDigits * 9 + 20)
        if abs(ruleThickness - neededThickness) > 2 {
            DispatchQueue.main.async { [weak self] in
                self?.ruleThickness = neededThickness
            }
        }
    }

    private func drawLineNumber(_ number: Int, atY y: CGFloat, isActive: Bool, colors: WorkbenchTheme.SyntaxColors) {
        let label = "\(number)"
        let font = isActive ? NSFont.monospacedSystemFont(ofSize: 11, weight: .bold) :
                              NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let color = isActive ? colors.activeLineGutterText : colors.gutterText

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let drawPoint = NSPoint(x: bounds.maxX - size.width - 8, y: y)
        str.draw(at: drawPoint)
    }
}
