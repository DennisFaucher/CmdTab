import Cocoa

final class ListView: NSView {
    var rows: [SwitchWindow] = [] {
        didSet { scrollOffset = 0; needsDisplay = true }
    }
    var query: String = "" {
        didSet { needsDisplay = true }
    }
    private(set) var selection: Int = 0
    var onClick: ((Int) -> Void)?

    private let hPad: CGFloat = 12
    private let rowHeight: CGFloat = 21
    /// Width of the 1–9 shortcut column. Reserved on every row, drawn only where a
    /// number exists, so the app names stay in one left edge.
    private let numberGutter: CGFloat = 18
    private let headerHeight: CGFloat = 26
    private let hintHeight: CGFloat = 20
    private let bottomPad: CGFloat = 6
    private let maxVisibleRows = 11
    private let cornerRadius: CGFloat = 12
    private var scrollOffset = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Sizing

    func desiredSize() -> NSSize {
        var textWidth: CGFloat = 0
        for row in rows.prefix(30) {
            textWidth = max(textWidth, Self.rowString(row, selected: false).size().width)
        }
        textWidth = max(textWidth, (query as NSString).size(withAttributes: [.font: Self.queryFont]).width + 30)
        // The footer is drawn on one line; never let a short window list make it clip.
        textWidth = max(textWidth, (Self.hintText as NSString).size(withAttributes: [.font: Self.hintFont]).width)
        if rows.isEmpty { textWidth = max(textWidth, 190) }

        let width = min(max(textWidth + numberGutter + hPad * 2 + 12, 400), 860)

        var height = hPad
        if !query.isEmpty { height += headerHeight }
        height += CGFloat(max(min(rows.count, maxVisibleRows), 1)) * rowHeight
        height += 10 + hintHeight + bottomPad
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    func setSelection(_ index: Int) {
        selection = max(0, min(index, max(0, rows.count - 1)))
        clampScroll()
        needsDisplay = true
    }

    private func clampScroll() {
        let visible = maxVisibleRows
        if selection < scrollOffset { scrollOffset = selection }
        if selection >= scrollOffset + visible { scrollOffset = selection - visible + 1 }
        scrollOffset = max(0, min(scrollOffset, max(0, rows.count - visible)))
    }

    // MARK: - Drawing

    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let titleFont = NSFont.systemFont(ofSize: 12.5)
    private static let queryFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let hintFont = NSFont.systemFont(ofSize: 10.5)
    static let hintText = "↑↓ move   ·   1–9 jump   ·   return opens   ·   type to search   ·   esc dismiss"

    private static func paragraph(_ color: NSColor) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.tighteningFactorForTruncation = 0.2
        return style
    }

    private static func rowString(_ row: SwitchWindow, selected: Bool) -> NSAttributedString {
        let primary = selected ? NSColor.white : NSColor.labelColor
        let secondary = selected ? NSColor.white.withAlphaComponent(0.72) : NSColor.secondaryLabelColor
        let style = paragraph(primary)

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: row.appName, attributes: [
            .font: nameFont, .foregroundColor: primary, .paragraphStyle: style,
        ]))
        text.append(NSAttributedString(string: ": ", attributes: [
            .font: titleFont, .foregroundColor: secondary, .paragraphStyle: style,
        ]))
        text.append(NSAttributedString(string: row.displayTitle, attributes: [
            .font: titleFont, .foregroundColor: secondary, .paragraphStyle: style,
        ]))
        return text
    }

    /// Right-aligned shortcut number for the 1–9 column.
    private static func numberString(_ number: Int, selected: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return NSAttributedString(string: "\(number)", attributes: [
            .font: numberFont,
            .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.62) : NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        // Background
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.985).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1
        path.stroke()

        var y = hPad

        if !query.isEmpty {
            let caret = NSRect(x: hPad, y: y + 3, width: 2, height: headerHeight - 8)
            NSColor.controlAccentColor.setFill()
            caret.fill()
            let text = NSAttributedString(string: query, attributes: [
                .font: Self.queryFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: Self.paragraph(NSColor.labelColor),
            ])
            let size = text.size()
            text.draw(in: NSRect(x: hPad + 8, y: y + (headerHeight - size.height) / 2,
                                 width: max(0, bounds.width - hPad * 2 - 8), height: size.height))
            y += headerHeight
        }

        if rows.isEmpty {
            let text = NSAttributedString(string: "No matching windows", attributes: [
                .font: Self.titleFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let size = text.size()
            text.draw(in: NSRect(x: hPad + 6, y: y + (rowHeight - size.height) / 2,
                                 width: bounds.width - hPad * 2, height: size.height))
        } else {
            clampScroll()
            let shown = min(rows.count, maxVisibleRows)

            for slot in 0..<shown {
                let index = scrollOffset + slot
                if index >= rows.count { break }
                let rect = NSRect(x: hPad, y: y + CGFloat(slot) * rowHeight,
                                  width: bounds.width - hPad * 2, height: rowHeight)

                if index == selection {
                    let pill = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: 1.5), xRadius: 6, yRadius: 6)
                    NSColor.controlAccentColor.setFill()
                    pill.fill()
                }

                // Numbers follow the row's rank, not the visible slot, so "5" means the
                // same row whether or not the list is scrolled.
                if index < 9 {
                    let label = Self.numberString(index + 1, selected: index == selection)
                    let labelSize = label.size()
                    label.draw(in: NSRect(
                        x: rect.minX + 2,
                        y: rect.midY - labelSize.height / 2,
                        width: numberGutter - 6,
                        height: labelSize.height
                    ))
                }

                let text = Self.rowString(rows[index], selected: index == selection)
                let size = text.size()
                text.draw(in: NSRect(x: rect.minX + 6 + numberGutter,
                                     y: rect.midY - size.height / 2,
                                     width: max(0, rect.width - 12 - numberGutter),
                                     height: size.height))
            }
        }

        drawHint(aboveBottomOf: bounds)
    }

    private func drawHint(aboveBottomOf bounds: NSRect) {
        let y = bounds.maxY - bottomPad - hintHeight
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: hPad, y: y - 5, width: bounds.width - hPad * 2, height: 1).fill()

        let text = NSAttributedString(string: Self.hintText, attributes: [
            .font: Self.hintFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let size = text.size()
        text.draw(in: NSRect(x: hPad + 6, y: y + (hintHeight - size.height) / 2,
                             width: bounds.width - hPad * 2 - 12, height: size.height))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shown = min(rows.count, maxVisibleRows)
        let top = hPad + (query.isEmpty ? 0 : headerHeight)
        guard point.y >= top else { return }
        let slot = Int((point.y - top) / rowHeight)
        guard slot >= 0, slot < shown else { return }
        let index = scrollOffset + slot
        guard index < rows.count else { return }
        onClick?(index)
    }
}
