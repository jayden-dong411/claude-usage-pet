import AppKit

// The pet window's view and its little rounded labels, shared by all four pets
// (Claude大小姐, GPT龙娘, Grok娘, DeepSeek娘): click = panel, double-click = jump, rub the mouse
// over her = petting, drag = move, right click = menu.

// MARK: - Pet view (click = panel, drag = move, right click = menu)

final class PetView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Mouse rubbed back and forth over `petRect` (the head / figure).
    var onPet: (() -> Void)?
    var petRect: () -> NSRect = { .zero }
    var onDragStart: (() -> Void)?
    var onDragMove: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var lastX: CGFloat = 0
    private var dragging = false
    private var pendingClick: DispatchWorkItem?
    private var rubDir: CGFloat = 0
    private var rubTurns: [Date] = []
    private var rubLastX: CGFloat?
    private var lastPet = Date.distantPast

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { rubLastX = nil; rubTurns.removeAll() }

    /// Counts left/right turns of the pointer over the figure; 4 turns within 1.6 s = petting.
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard petRect().contains(p) else { rubLastX = nil; return }
        defer { rubLastX = p.x }
        guard let last = rubLastX else { return }
        let dx = p.x - last
        guard abs(dx) > 1.5 else { return }
        let dir: CGFloat = dx > 0 ? 1 : -1
        if rubDir != 0 && dir != rubDir {
            let now = Date()
            rubTurns = rubTurns.filter { now.timeIntervalSince($0) < 1.6 } + [now]
            if rubTurns.count >= 4 && now.timeIntervalSince(lastPet) > 6 {
                lastPet = now
                rubTurns.removeAll()
                onPet?()
            }
        }
        rubDir = dir
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        lastX = startMouse.x
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        if !dragging && hypot(dx, dy) > 3 { dragging = true; onDragStart?() }
        if dragging {
            window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
            onDragMove?(p.x - lastX)
            lastX = p.x
        }
    }

    /// A second click within 0.3 s is a double-click (jump); otherwise the click fires after that wait.
    override func mouseUp(with event: NSEvent) {
        defer { dragging = false }
        if dragging { onDragEnd?(); return }
        if let p = pendingClick {
            p.cancel()
            pendingClick = nil
            onDoubleClick?()
            return
        }
        let w = DispatchWorkItem { [weak self] in
            self?.pendingClick = nil
            self?.onClick?()
        }
        pendingClick = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?() { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }
}

/// Small rounded label whose colours follow light / dark mode.
final class Chip: NSView {
    let label = NSTextField(labelWithString: "")
    var padding = NSSize(width: 8, height: 3)
    var fill: NSColor { didSet { applyColors() } }
    var border: NSColor? { didSet { applyColors() } }
    var borderWidth: CGFloat = 1 { didSet { applyColors() } }

    init(fill: NSColor, text: NSColor, border: NSColor? = nil, font: NSFont) {
        self.fill = fill
        self.border = border
        super.init(frame: .zero)
        wantsLayer = true
        label.font = font
        label.textColor = text
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        addSubview(label)
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border?.cgColor
            layer?.borderWidth = border == nil ? 0 : borderWidth
        }
    }

    /// Lays the chip out centred horizontally at `y`, wrapping at `maxWidth`.
    func set(_ text: String, centerX: CGFloat, y: CGFloat, maxWidth: CGFloat, radius: CGFloat? = nil) {
        label.stringValue = text
        label.preferredMaxLayoutWidth = maxWidth - padding.width * 2
        let s = label.sizeThatFits(NSSize(width: maxWidth - padding.width * 2, height: 200))
        let w = ceil(min(maxWidth, s.width + padding.width * 2))
        let h = ceil(s.height + padding.height * 2)
        frame = NSRect(x: round(centerX - w / 2), y: y, width: w, height: h)
        label.frame = NSRect(x: padding.width, y: padding.height, width: w - padding.width * 2, height: s.height)
        layer?.cornerRadius = radius ?? h / 2
    }
}
