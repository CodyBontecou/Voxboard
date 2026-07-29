import AppKit

/// Marks a responder that owns raw keyboard input and should never start hint mode.
protocol MacKeyboardHintSuppressingResponder: AnyObject {}

/// Generates deterministic, prefix-free labels for keyboard hint targets.
enum MacKeyboardHintLabelGenerator {
    static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm")

    static func labels(count: Int) -> [String] {
        guard count > 0 else { return [] }

        let base = alphabet.count
        var length = 1
        var capacity = base
        while count > capacity {
            length += 1
            if capacity > Int.max / base {
                break
            }
            capacity *= base
        }

        return (0..<count).map { index in
            var value = index
            var characters = Array(repeating: alphabet[0], count: length)
            for position in (0..<length).reversed() {
                characters[position] = alphabet[value % base]
                value /= base
            }
            return String(characters)
        }
    }
}

@MainActor
final class MacKeyboardHintCenter: NSObject {
    static let shared = MacKeyboardHintCenter()

    private struct Candidate {
        let frame: NSRect
        let activationPoint: NSPoint
        let priority: Int
    }

    private struct Target {
        let label: String
        let frame: NSRect
        let activationPoint: NSPoint
    }

    private struct Session {
        let window: NSWindow
        let panel: MacKeyboardHintPanel
        let targets: [Target]
        var typedPrefix: String
    }

    private var eventMonitor: Any?
    private var session: Session?

    private override init() {
        super.init()
    }

    func start() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .keyDown,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .scrollWheel,
            ]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(windowDidChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    func stop() {
        dismissHints()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard session != nil else {
            return handleTrigger(event)
        }

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            dismissHints()
            return event
        case .keyDown:
            return handleHintKey(event)
        default:
            return event
        }
    }

    private func handleTrigger(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              !event.isARepeat,
              isHintShortcut(event),
              let window = NSApplication.shared.keyWindow,
              window.isVisible,
              !window.isMiniaturized,
              !isShortcutCaptureActive(in: window) else {
            return event
        }

        return showHints(in: window) ? nil : event
    }

    private func handleHintKey(_ event: NSEvent) -> NSEvent? {
        guard var activeSession = session else { return event }

        if event.isARepeat {
            return nil
        }

        if !isUnmodified(event) {
            dismissHints()
            return event
        }

        switch event.keyCode {
        case 53: // Escape
            dismissHints()
            return nil
        case 51: // Delete / Backspace
            guard !activeSession.typedPrefix.isEmpty else {
                NSSound.beep()
                return nil
            }
            activeSession.typedPrefix.removeLast()
            session = activeSession
            activeSession.panel.overlayView.typedPrefix = activeSession.typedPrefix
            return nil
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1,
              let character = characters.first,
              MacKeyboardHintLabelGenerator.alphabet.contains(character) else {
            NSSound.beep()
            dismissHints()
            return nil
        }

        activeSession.typedPrefix.append(character)
        let matches = activeSession.targets.filter {
            $0.label.hasPrefix(activeSession.typedPrefix)
        }

        guard !matches.isEmpty else {
            NSSound.beep()
            dismissHints()
            return nil
        }

        if let target = matches.first(where: { $0.label == activeSession.typedPrefix }) {
            let window = activeSession.window
            dismissHints()
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.click(target.activationPoint, in: window)
            }
            return nil
        }

        session = activeSession
        activeSession.panel.overlayView.typedPrefix = activeSession.typedPrefix
        return nil
    }

    private func showHints(in window: NSWindow) -> Bool {
        let candidates = discoverCandidates(in: window)
        guard !candidates.isEmpty else {
            NSSound.beep()
            return false
        }

        let labels = MacKeyboardHintLabelGenerator.labels(count: candidates.count)
        let targets = zip(candidates, labels).map { candidate, label in
            Target(
                label: label,
                frame: candidate.frame,
                activationPoint: candidate.activationPoint
            )
        }
        let overlayTargets = targets.map {
            MacKeyboardHintOverlayTarget(label: $0.label, screenFrame: $0.frame)
        }
        let panel = MacKeyboardHintPanel(
            parentWindow: window,
            targets: overlayTargets
        )

        session = Session(
            window: window,
            panel: panel,
            targets: targets,
            typedPrefix: ""
        )
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        return true
    }

    private func dismissHints() {
        guard let activeSession = session else { return }
        session = nil
        activeSession.window.removeChildWindow(activeSession.panel)
        activeSession.panel.orderOut(nil)
    }

    private func discoverCandidates(in window: NSWindow) -> [Candidate] {
        guard let contentView = window.contentView else { return [] }
        let rootView = contentView.superview ?? contentView
        var candidates: [Candidate] = []
        collectCandidates(from: rootView, in: window, into: &candidates)

        let prioritySorted = candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if abs(lhs.frame.maxY - rhs.frame.maxY) > 4 {
                return lhs.frame.maxY > rhs.frame.maxY
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        var unique: [Candidate] = []
        for candidate in prioritySorted {
            let duplicatesExistingTarget = unique.contains { existing in
                let intersection = existing.frame.intersection(candidate.frame)
                guard !intersection.isNull, !intersection.isEmpty else { return false }
                let smallerArea = min(
                    existing.frame.width * existing.frame.height,
                    candidate.frame.width * candidate.frame.height
                )
                guard smallerArea > 0 else { return false }
                return intersection.width * intersection.height / smallerArea > 0.88
                    && hypot(
                        existing.activationPoint.x - candidate.activationPoint.x,
                        existing.activationPoint.y - candidate.activationPoint.y
                    ) < 10
            }
            if !duplicatesExistingTarget {
                unique.append(candidate)
            }
        }

        return unique.sorted { lhs, rhs in
            if abs(lhs.frame.maxY - rhs.frame.maxY) > 4 {
                return lhs.frame.maxY > rhs.frame.maxY
            }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    private func collectCandidates(
        from view: NSView,
        in window: NSWindow,
        into candidates: inout [Candidate]
    ) {
        guard !view.isHidden, view.alphaValue > 0.01 else { return }

        if let segmentedControl = view as? NSSegmentedControl,
           segmentedControl.isEnabled,
           segmentedControl.segmentCount > 1 {
            collectSegments(
                from: segmentedControl,
                in: window,
                into: &candidates
            )
        } else if let control = view as? NSControl,
                  isSelectable(control),
                  let frame = visibleScreenFrame(for: view, in: window) {
            candidates.append(Candidate(
                frame: frame,
                activationPoint: NSPoint(x: frame.midX, y: frame.midY),
                priority: 0
            ))
        } else if let textView = view as? NSTextView,
                  textView.isSelectable || textView.isEditable,
                  let frame = visibleScreenFrame(for: view, in: window) {
            candidates.append(Candidate(
                frame: frame,
                activationPoint: NSPoint(x: frame.midX, y: frame.midY),
                priority: 0
            ))
        } else if isSwiftUIFocusRing(view),
                  let frame = visibleScreenFrame(for: view, in: window) {
            candidates.append(Candidate(
                frame: frame,
                activationPoint: NSPoint(x: frame.midX, y: frame.midY),
                priority: 1
            ))
        }

        for subview in view.subviews {
            collectCandidates(from: subview, in: window, into: &candidates)
        }
    }

    private func collectSegments(
        from control: NSSegmentedControl,
        in window: NSWindow,
        into candidates: inout [Candidate]
    ) {
        let segmentWidth = control.bounds.width / CGFloat(control.segmentCount)
        guard segmentWidth > 0 else { return }

        for index in 0..<control.segmentCount where control.isEnabled(forSegment: index) {
            let localFrame = NSRect(
                x: control.bounds.minX + (CGFloat(index) * segmentWidth),
                y: control.bounds.minY,
                width: segmentWidth,
                height: control.bounds.height
            )
            let frameInWindow = control.convert(localFrame, to: nil)
            let screenFrame = window.convertToScreen(frameInWindow)
                .intersection(window.frame)
            guard screenFrame.width >= 4, screenFrame.height >= 4 else { continue }
            candidates.append(Candidate(
                frame: screenFrame,
                activationPoint: NSPoint(x: screenFrame.midX, y: screenFrame.midY),
                priority: 0
            ))
        }
    }

    private func visibleScreenFrame(for view: NSView, in window: NSWindow) -> NSRect? {
        let visibleRect = view.visibleRect.intersection(view.bounds)
        guard !visibleRect.isNull, !visibleRect.isEmpty else { return nil }

        let frameInWindow = view.convert(visibleRect, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
            .intersection(window.frame)
        guard !screenFrame.isNull,
              screenFrame.width >= 4,
              screenFrame.height >= 4 else {
            return nil
        }
        return screenFrame
    }

    private func isSelectable(_ control: NSControl) -> Bool {
        guard control.isEnabled,
              !(control is NSProgressIndicator),
              !(control is NSScroller),
              !(control is NSTableView),
              !(control is NSOutlineView) else {
            return false
        }

        if let textField = control as? NSTextField {
            return textField.isEditable || textField.isSelectable
        }
        return control.action != nil || control.target != nil
    }

    /// SwiftUI renders many buttons itself, with a small AppKit focus-ring view
    /// carrying the exact tappable frame. Native controls remain discoverable as
    /// `NSControl`; this fallback covers SwiftUI-drawn buttons and navigation links.
    private func isSwiftUIFocusRing(_ view: NSView) -> Bool {
        String(reflecting: type(of: view)).contains("FocusRingView")
    }

    private func isShortcutCaptureActive(in window: NSWindow) -> Bool {
        window.firstResponder is MacKeyboardHintSuppressingResponder
    }

    private func isHintShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection([.command, .option, .control, .shift, .function])
        return modifiers == [.control] && event.keyCode == 11 // Control-B
    }

    private func isUnmodified(_ event: NSEvent) -> Bool {
        event.modifierFlags
            .intersection([.command, .option, .control, .shift, .function])
            .isEmpty
    }

    private func click(_ screenPoint: NSPoint, in window: NSWindow) {
        guard window.isVisible, !window.isMiniaturized else { return }

        let location = window.convertPoint(fromScreen: screenPoint)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            NSSound.beep()
            return
        }

        NSApplication.shared.postEvent(mouseDown, atStart: false)
        NSApplication.shared.postEvent(mouseUp, atStart: false)
    }

    @objc
    private func applicationDidResignActive(_ notification: Notification) {
        dismissHints()
    }

    @objc
    private func windowDidChange(_ notification: Notification) {
        guard let activeSession = session,
              let changedWindow = notification.object as? NSWindow,
              changedWindow === activeSession.window else {
            return
        }
        dismissHints()
    }
}

private struct MacKeyboardHintOverlayTarget {
    let label: String
    let screenFrame: NSRect
}

private final class MacKeyboardHintPanel: NSPanel {
    let overlayView: MacKeyboardHintOverlayView

    init(parentWindow: NSWindow, targets: [MacKeyboardHintOverlayTarget]) {
        overlayView = MacKeyboardHintOverlayView(
            parentWindowFrame: parentWindow.frame,
            targets: targets
        )
        super.init(
            contentRect: parentWindow.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = parentWindow.level
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = overlayView
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MacKeyboardHintOverlayView: NSView {
    private let parentWindowFrame: NSRect
    private let targets: [MacKeyboardHintOverlayTarget]

    var typedPrefix = "" {
        didSet { needsDisplay = true }
    }

    init(parentWindowFrame: NSRect, targets: [MacKeyboardHintOverlayTarget]) {
        self.parentWindowFrame = parentWindowFrame
        self.targets = targets
        super.init(frame: NSRect(origin: .zero, size: parentWindowFrame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for target in targets where target.label.hasPrefix(typedPrefix) {
            drawBadge(for: target)
        }
    }

    private func drawBadge(for target: MacKeyboardHintOverlayTarget) {
        let label = target.label.uppercased()
        let prefixLength = typedPrefix.count
        let prefix = String(label.prefix(prefixLength))
        let suffix = String(label.dropFirst(prefixLength))
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]
        let prefixWidth = ceil((prefix as NSString).size(withAttributes: attributes).width)
        let suffixWidth = ceil((suffix as NSString).size(withAttributes: attributes).width)
        let horizontalPadding: CGFloat = 5
        let badgeSize = NSSize(
            width: max(20, prefixWidth + suffixWidth + (horizontalPadding * 2)),
            height: 20
        )

        let targetFrame = target.screenFrame.offsetBy(
            dx: -parentWindowFrame.minX,
            dy: -parentWindowFrame.minY
        )
        var badgeRect = NSRect(
            x: targetFrame.minX + 2,
            y: targetFrame.maxY - badgeSize.height - 2,
            width: badgeSize.width,
            height: badgeSize.height
        )
        badgeRect.origin.x = min(
            max(2, badgeRect.origin.x),
            max(2, bounds.maxX - badgeRect.width - 2)
        )
        badgeRect.origin.y = min(
            max(2, badgeRect.origin.y),
            max(2, bounds.maxY - badgeRect.height - 2)
        )

        let path = NSBezierPath(
            roundedRect: badgeRect,
            xRadius: 4,
            yRadius: 4
        )
        NSColor.systemYellow.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.82).setStroke()
        path.lineWidth = 1
        path.stroke()

        let textRect = badgeRect.insetBy(dx: horizontalPadding, dy: 2)
        var textX = textRect.minX
        if !prefix.isEmpty {
            let prefixBackground = NSRect(
                x: badgeRect.minX,
                y: badgeRect.minY,
                width: prefixWidth + horizontalPadding,
                height: badgeRect.height
            )
            NSColor.black.withAlphaComponent(0.9).setFill()
            NSBezierPath(
                roundedRect: prefixBackground,
                xRadius: 4,
                yRadius: 4
            ).fill()
            (prefix as NSString).draw(
                in: NSRect(
                    x: textX,
                    y: textRect.minY,
                    width: prefixWidth,
                    height: textRect.height
                ),
                withAttributes: attributes.merging([.foregroundColor: NSColor.white]) { _, new in new }
            )
            textX += prefixWidth
        }

        if !suffix.isEmpty {
            (suffix as NSString).draw(
                in: NSRect(
                    x: textX,
                    y: textRect.minY,
                    width: suffixWidth,
                    height: textRect.height
                ),
                withAttributes: attributes.merging([.foregroundColor: NSColor.black]) { _, new in new }
            )
        }
    }
}
