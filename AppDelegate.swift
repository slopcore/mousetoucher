import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var multitouchManager: MultitouchManager?
    var isEnabled = true
    private var dragEventTap: CFMachPort?
    private var dragEventTapRunLoopSource: CFRunLoopSource?
    private let dragEventSource: CGEventSource? = {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }

        // Let physical mouse and keyboard input through immediately while the synthetic button
        // is held. This source is used only by drag lock; ordinary tap-to-click keeps its old
        // event path.
        source.localEventsSuppressionInterval = 0
        let permitAllLocalEvents: CGEventFilterMask = [
            .permitLocalMouseEvents,
            .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents
        ]
        source.setLocalEventsFilterDuringSuppressionState(
            permitAllLocalEvents,
            state: .eventSuppressionStateSuppressionInterval
        )
        source.setLocalEventsFilterDuringSuppressionState(
            permitAllLocalEvents,
            state: .eventSuppressionStateRemoteMouseDrag
        )
        return source
    }()
    private var hasStartedMultitouch = false
    private var hasRequestedAccessibilityPrompt = false
    private var hasShownAccessibilityInstructions = false
    private weak var dragLockStatusItem: NSMenuItem?
    /// Click state stamped on transformed drag events (1 char, 2 word, 3 line selection).
    private var dragClickState: Int64 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        ensureAccessibilityAndStart()
    }

    @objc func showAccessibilityInstructions() {
        guard !hasShownAccessibilityInstructions else { return }
        hasShownAccessibilityInstructions = true
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Mouse Toucher needs accessibility permissions to simulate clicks.\n\nPlease grant permission in:\nSystem Settings > Privacy & Security > Accessibility\n\nAfter enabling, return to Mouse Toucher. The app will begin working as soon as permission is granted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else if response == .alertSecondButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        multitouchManager?.stop()
        tearDownDragEventTap()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "Mouse Toucher")
        }

        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Tap to Click: Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.state = isEnabled ? .on : .off
        menu.addItem(enabledItem)

        let dragLockItem = NSMenuItem(title: "Drag Lock: Unlocked (Two-Finger Tap)", action: nil, keyEquivalent: "")
        dragLockItem.isEnabled = false
        menu.addItem(dragLockItem)
        dragLockStatusItem = dragLockItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(buildRightClickZoneItem())

        menu.addItem(NSMenuItem.separator())
        let accessibilityItem = NSMenuItem(title: "Accessibility Instructions…", action: #selector(showAccessibilityInstructions), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Mouse Toucher", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Mouse Toucher", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc func toggleEnabled() {
        isEnabled.toggle()
        if let menu = statusItem?.menu,
           let item = menu.items.first {
            item.state = isEnabled ? .on : .off
            item.title = isEnabled ? "Tap to Click: Enabled" : "Tap to Click: Disabled"
        }
        multitouchManager?.setEnabled(isEnabled)
    }

    /// Submenu letting the user pick where the left/right click boundary sits on the mouse surface.
    private func buildRightClickZoneItem() -> NSMenuItem {
        let parentItem = NSMenuItem(title: "Right Click Zone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        var choices = Preferences.rightClickThresholdChoices
        let current = Preferences.rightClickThreshold
        // Surface a value set outside the app (e.g. via `defaults write`) so it's still selectable.
        if !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }

        for choice in choices {
            let percent = Int((choice * 100).rounded())
            let item = NSMenuItem(
                title: "Right side starts at \(percent)%",
                action: #selector(selectRightClickThreshold(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice
            item.state = choice == current ? .on : .off
            submenu.addItem(item)
        }

        parentItem.submenu = submenu
        return parentItem
    }

    @objc func selectRightClickThreshold(_ sender: NSMenuItem) {
        guard let threshold = sender.representedObject as? Float else { return }

        Preferences.rightClickThreshold = threshold
        multitouchManager?.rightClickThreshold = Preferences.rightClickThreshold

        guard let submenu = sender.menu else { return }
        for item in submenu.items {
            item.state = (item.representedObject as? Float) == Preferences.rightClickThreshold ? .on : .off
        }
    }

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let alert = NSAlert()
        alert.messageText = "Mouse Toucher"
        alert.informativeText = """
        Tap-to-click for Magic Mouse

        • Tap left side for left click
        • Tap right side for right click
        • Two-finger tap to toggle drag lock

        Version \(version)

        Uses private MultitouchSupport framework
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quit() {
        multitouchManager?.stop()
        NSApplication.shared.terminate(nil)
    }

    private func ensureAccessibilityAndStart() {
        if AXIsProcessTrusted() {
            startMultitouchManager()
            return
        }

        requestAccessibilityPermissionIfNeeded()
        waitForAccessibilityPermission()
    }

    private func startMultitouchManager() {
        guard !hasStartedMultitouch else { return }
        hasStartedMultitouch = true

        let canTransformDragEvents = setUpDragEventTap()
        let manager = MultitouchManager()
        manager.setDragLockAvailable(canTransformDragEvents)
        multitouchManager = manager

        manager.onClickSynthesized = { [weak self] location, isRightClick, clickCount in
            self?.synthesizeClick(at: location, isRightClick: isRightClick, clickCount: clickCount)
        }
        manager.onHoldDragChanged = { [weak self] location, isDown, clickState in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if isDown {
                    guard self.isOnActiveDisplay(location) else { return }
                    self.dragClickState = Int64(clickState)
                    self.setDragEventTapEnabled(true)
                    self.postButton(.leftMouseDown, at: location, clickState: clickState)
                } else {
                    // Always release, never leave the button stuck down.
                    self.postButton(.leftMouseUp, at: location, clickState: clickState)
                    if self.multitouchManager?.isDragLocked != true {
                        self.setDragEventTapEnabled(false)
                    }
                    self.dragClickState = 1
                }
            }
        }
        manager.onDragLockChanged = { [weak self] location, isLocked in
            guard let self = self else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Enable the transformer before mouse-down, and disable it only after mouse-up.
                // It is therefore absent from the normal one-finger click path.
                if isLocked {
                    self.dragClickState = 1
                    self.setDragEventTapEnabled(true)
                    self.synthesizeDragLock(at: location, isLocked: true)
                } else {
                    self.synthesizeDragLock(at: location, isLocked: false)
                    self.setDragEventTapEnabled(false)
                }
                self.updateDragLockStatus(isLocked: isLocked)
            }
        }
        manager.start()

        if !canTransformDragEvents {
            dragLockStatusItem?.title = "Drag Lock: Unavailable"
        }
    }

    /// Creates a session-level event transformer and leaves it disabled until drag lock starts.
    /// Session-level conversion delivers drag semantics to applications without intercepting the
    /// HID input path used by Magic Mouse touch detection.
    private func setUpDragEventTap() -> Bool {
        guard dragEventTap == nil else { return true }

        let eventMask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: dragEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        CGEvent.tapEnable(tap: eventTap, enable: false)
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        dragEventTap = eventTap
        dragEventTapRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        return true
    }

    private func setDragEventTapEnabled(_ enabled: Bool) {
        guard let eventTap = dragEventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: enabled)
    }

    private func tearDownDragEventTap() {
        if let runLoopSource = dragEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap = dragEventTap {
            CFMachPortInvalidate(eventTap)
        }
        dragEventTapRunLoopSource = nil
        dragEventTap = nil
    }

    fileprivate func handleDragEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if multitouchManager?.isDragLocked == true || multitouchManager?.isHoldDragging == true {
                setDragEventTapEnabled(true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .mouseMoved else {
            return Unmanaged.passUnretained(event)
        }

        event.type = .leftMouseDragged
        event.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(CGMouseButton.left.rawValue)
        )
        event.setIntegerValueField(.mouseEventClickState, value: dragClickState)
        event.setDoubleValueField(.mouseEventPressure, value: 1.0)
        return Unmanaged.passUnretained(event)
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard !hasRequestedAccessibilityPrompt else { return }
        hasRequestedAccessibilityPrompt = true

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func waitForAccessibilityPermission() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }

            if AXIsProcessTrusted() {
                self.startMultitouchManager()
            } else {
                self.waitForAccessibilityPermission()
            }
        }
    }

    /// True if the point falls on an active display. Coordinates here are in Quartz global
    /// space (origin top-left), which is what `CGEvent.location` reports — so this must not be
    /// compared against `NSScreen.frame`, which uses Cocoa's bottom-left origin.
    private func isOnActiveDisplay(_ location: CGPoint) -> Bool {
        guard location.x.isFinite, location.y.isFinite else { return false }

        var matchingDisplayCount: UInt32 = 0
        // Fail open: if the query itself fails, don't silently swallow the click.
        guard CGGetDisplaysWithPoint(location, 0, nil, &matchingDisplayCount) == .success else {
            return true
        }
        return matchingDisplayCount > 0
    }

    func synthesizeClick(at location: CGPoint, isRightClick: Bool, clickCount: Int = 1) {
        guard isOnActiveDisplay(location) else { return }

        // clickState is what apps read as NSEvent.clickCount: 2 selects a word, 3 a line/paragraph.
        // Synthetic events don't get it computed for them, so it must be stamped explicitly.
        let button: CGMouseButton = isRightClick ? .right : .left
        let downType: CGEventType = isRightClick ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRightClick ? .rightMouseUp : .leftMouseUp
        let flags = currentModifierFlags()

        for type in [downType, upType] {
            if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                event.flags = flags   // Shift-tap extends selection, Cmd-tap opens in new tab, etc.
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Press/release for tap-then-hold selection. Uses the drag-lock event source so physical
    /// mouse movement is not suppressed while the synthetic button is held.
    private func postButton(_ type: CGEventType, at location: CGPoint, clickState: Int) {
        if let event = CGEvent(mouseEventSource: dragEventSource, mouseType: type, mouseCursorPosition: location, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            event.flags = currentModifierFlags()
            event.post(tap: .cghidEventTap)
        }
    }

    private func currentModifierFlags() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    /// Holds or releases the primary mouse button. Pointer movement produced by the physical
    /// mouse while the button is held is interpreted by macOS as dragging.
    func synthesizeDragLock(at location: CGPoint, isLocked: Bool) {
        // When locking, verify location is on an active display.
        // When unlocking, always post leftMouseUp unconditionally so the primary mouse button
        // is never permanently stuck down.
        if isLocked {
            guard isOnActiveDisplay(location) else { return }
        }

        let eventType: CGEventType = isLocked ? .leftMouseDown : .leftMouseUp
        if let event = CGEvent(
            mouseEventSource: dragEventSource,
            mouseType: eventType,
            mouseCursorPosition: location,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func updateDragLockStatus(isLocked: Bool) {
        dragLockStatusItem?.title = isLocked
            ? "Drag Lock: Locked (Two-Finger Tap to Release)"
            : "Drag Lock: Unlocked (Two-Finger Tap)"
    }
}

private let dragEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    return appDelegate.handleDragEvent(type: type, event: event)
}
