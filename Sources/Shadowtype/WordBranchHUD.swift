// WordBranchHUD — the "auto show word alternatives" branch menu (FlowIn port): a small numbered
// list anchored under the caret while a mid-word ghost is live. Rows are 1-ordered; typing the
// digit inserts that word (the digit tap consults WordCompletion.select — a digit outside the
// visible rows is always ordinary typing).
//
// Non-activating borderless NSPanel, exactly like RewriteHUD: it must never steal focus from the
// host app (the caret stays live; the digits arrive through the event tap, not the panel).
// ignoresMouseEvents for now — FlowIn's confirmed interaction is digits, and a click-to-pick row
// would need the panel to accept events over the host's own click targets. Main-thread only.
import Cocoa

final class WordBranchHUD {
    private let panel: NSPanel
    private let stack: NSStackView
    private let hPad: CGFloat = 10
    private let vPad: CGFloat = 6
    private let gapBelowCaret: CGFloat = 6
    private var rowLabels: [NSTextField] = []

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 28),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -hPad),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: vPad),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -vPad),
        ])
        panel.contentView = effect
    }

    // Show (or refresh) the menu under the caret. Empty/nil → hide. The digit gutter is rendered
    // here ("1  message") because the digit tap accepts by visible-row index — the HUD IS the
    // row numbering the user reads.
    func show(menu: [String]?, at caretRect: CGRect) {
        guard let menu, !menu.isEmpty else { hide(); return }
        if rowLabels.count != menu.count { rebuildRows(count: menu.count) }
        for (i, word) in menu.enumerated() {
            rowLabels[i].stringValue = "\(i + 1)  \(word)"
        }
        // Size to content, then place under the caret (same flip logic shape as RewriteHUD.place).
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 28)
        var w = max(140, size.width)
        if w > 360 { w = 360 }
        let h = max(24, size.height)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(caretRect.origin, $0.frame, false) })
            ?? NSScreen.main
        var x = caretRect.minX
        var y = caretRect.minY - h - gapBelowCaret
        if let vf = screen?.visibleFrame {
            if x + w > vf.maxX { x = vf.maxX - w - 4 }
            if y < vf.minY { y = caretRect.maxY + gapBelowCaret }   // flip above near screen bottom
        }
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    private func rebuildRows(count: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowLabels = (0..<count).map { _ in
            let l = NSTextField(labelWithString: "")
            l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            l.textColor = .labelColor
            return l
        }
        rowLabels.forEach { stack.addArrangedSubview($0) }
    }
}
