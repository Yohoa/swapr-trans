import Foundation
import Cocoa
import CoreGraphics
import Carbon
import os

private let axLogger = Logger(subsystem: "com.swaprtrans", category: "Accessibility")

public final class TranslateMonitor: @unchecked Sendable {
    public static let shared = TranslateMonitor()
    public static var isHudVisible: Bool = false
    public static var cachedHudFrame: NSRect = .zero
    public static var hudShownDate: Date = .distantPast

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isReplayingKey: Bool = false
    public var isMonitoring: Bool = false

    // Right-click / Trackpad double tap tracking
    private var lastRightMouseDownTime: Date = Date.distantPast
    private var lastRightMouseDownPoint: CGPoint = .zero

    // Shortcut configuration cache
    private var targetKeyCode: Int64 = 49
    private var targetMods: String = "none"
    private var requireCmd: Bool = false
    private var requireAlt: Bool = false
    private var requireCtrl: Bool = false
    private var requireShift: Bool = false
    private var isRightClickMode: Bool = false
    private var isSingleKeyMode: Bool = true
    public var isDetecting: Bool = false
    private var currentTranslationTask: Task<Void, Never>?

    // True while the user is continuously typing (incl. IME composition). A fresh selection can only
    // be made via mouse / navigation keys / Cmd-Ctrl combos, all of which reset this flag. While set,
    // a single-key shortcut (e.g. Space) is plain typing and must pass through untouched; otherwise the
    // Cmd+C fallback would leak a "c" into an active IME composition (e.g. "woshis" -> "我是谁错").
    private var isTypingSequence: Bool = false
    private static let selectionNavKeyCodes: Set<Int64> = [
        123, 124, 125, 126, // arrows
        115, 119, 116, 121, // home, end, page up, page down
        48, 53              // tab, esc
    ]

    // Apps (notably Flutter / Electron) publish AX selection asynchronously, and the event tap sees the
    // trigger key before the app has even processed the preceding Shift+Arrow. If the trigger arrives
    // shortly after a selection-changing input, poll AX until the selection settles.
    private var lastSelectionChangeUptime: TimeInterval = 0
    private static let selectionSettleWindow: TimeInterval = 0.30
    private static let selectionSettleHardCap: TimeInterval = 0.30
    private static let selectionPollIntervalUs: useconds_t = 30_000

    // Cached app filter settings (safe for C callback access)
    private var cachedIgnoredBundleIds: Set<String> = []
    private var cachedIgnoredKeywords: Set<String> = ["swaprtrans", "swapr trans"]

    private init() {}

    public func restartMonitoring(with shortcut: TranslationShortcut? = nil) {
        stopMonitoring()
        startMonitoring(with: shortcut)
    }

    public func syncShortcutConfig(with shortcut: TranslationShortcut) {
        self.targetKeyCode = shortcut.keyCode
        self.targetMods = shortcut.modifiers.lowercased()
        self.requireCmd = self.targetMods.contains("cmd")
        self.requireAlt = self.targetMods.contains("alt") || self.targetMods.contains("opt")
        self.requireCtrl = self.targetMods.contains("ctrl")
        self.requireShift = self.targetMods.contains("shift")
        self.isRightClickMode = (self.targetKeyCode == -2 || self.targetMods.contains("right_double") || self.targetMods.contains("double"))
        self.isSingleKeyMode = !self.isRightClickMode && !self.requireCmd && !self.requireAlt && !self.requireCtrl && !self.requireShift
        
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.cachedIgnoredBundleIds = SwaprTransConfig.shared.ignoredAppBundleIdentifiers
                self.cachedIgnoredKeywords = SwaprTransConfig.shared.ignoredAppNameKeywords
            }
        } else {
            Task { @MainActor in
                self.cachedIgnoredBundleIds = SwaprTransConfig.shared.ignoredAppBundleIdentifiers
                self.cachedIgnoredKeywords = SwaprTransConfig.shared.ignoredAppNameKeywords
            }
        }
    }

    public func startMonitoring(with shortcut: TranslationShortcut? = nil) {
        guard !isMonitoring else { return }

        // Sync shortcut configuration without triggering deadlocks
        if let sc = shortcut {
            self.syncShortcutConfig(with: sc)
        } else if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.syncShortcutConfig(with: SwaprTransConfig.shared.shortcut)
            }
        } else {
            Task { @MainActor in
                self.syncShortcutConfig(with: SwaprTransConfig.shared.shortcut)
            }
        }

        var mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        mask |= (1 << CGEventType.rightMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByUserInput {
                    return nil
                }
                if type == .tapDisabledByTimeout {
                    if let port = TranslateMonitor.shared.eventTap {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                // Dismiss HUD when clicking outside (do not dismiss when clicking inside HUD so buttons trigger properly)
                if type == .leftMouseDown {
                    TranslateMonitor.shared.isTypingSequence = false
                    TranslateMonitor.shared.lastSelectionChangeUptime = ProcessInfo.processInfo.systemUptime
                    if TranslateMonitor.isHudVisible {
                        let loc = event.location
                        // CGEvent global coordinates are anchored to the primary display's top-left,
                        // so the flip must use the primary screen height
                        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080.0
                        let cocoaPoint = NSPoint(x: loc.x, y: primaryHeight - loc.y)
                        let hitRect = TranslateMonitor.cachedHudFrame.insetBy(dx: -8, dy: -8)

                        // Only dismiss when click point is outside HUD window and HUD has been shown for > 150ms
                        if !hitRect.contains(cocoaPoint) {
                            if Date().timeIntervalSince(TranslateMonitor.hudShownDate) > 0.15 {
                                DispatchQueue.main.async {
                                    TranslationHudController.shared.hide()
                                }
                            }
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                // Handle right double click / trackpad two-finger double tap
                if type == .rightMouseDown {
                    TranslateMonitor.shared.isTypingSequence = false
                    if TranslateMonitor.shared.isRightClickMode {
                        let now = Date()
                        let timeDiff = now.timeIntervalSince(TranslateMonitor.shared.lastRightMouseDownTime)
                        let dx = event.location.x - TranslateMonitor.shared.lastRightMouseDownPoint.x
                        let dy = event.location.y - TranslateMonitor.shared.lastRightMouseDownPoint.y
                        let dist = sqrt(dx * dx + dy * dy)
                        let clickCount = event.getIntegerValueField(.mouseEventClickState)

                        if clickCount >= 2 || (timeDiff < 0.50 && dist < 65.0) {
                            TranslateMonitor.shared.lastRightMouseDownTime = Date.distantPast
                            TranslateMonitor.shared.lastRightMouseDownPoint = .zero
                            TranslateMonitor.shared.handleTrigger(shouldReplay: false)
                            return nil // Suppress right click context menu
                        } else {
                            TranslateMonitor.shared.lastRightMouseDownTime = now
                            TranslateMonitor.shared.lastRightMouseDownPoint = event.location
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown {
                    // Pass through if currently replaying previously intercepted key
                    if TranslateMonitor.shared.isReplayingKey {
                        return Unmanaged.passUnretained(event)
                    }

                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let m = TranslateMonitor.shared
                    let keyFlags = event.flags
                    let wasTyping = m.isTypingSequence
                    m.isTypingSequence = !keyFlags.contains(.maskCommand)
                        && !keyFlags.contains(.maskControl)
                        && !TranslateMonitor.selectionNavKeyCodes.contains(keyCode)
                    if !m.isTypingSequence && keyCode != m.targetKeyCode {
                        m.lastSelectionChangeUptime = ProcessInfo.processInfo.systemUptime
                    }

                    // Esc key dismisses HUD
                    if TranslateMonitor.isHudVisible && keyCode == 53 {
                        DispatchQueue.main.async {
                            TranslationHudController.shared.hide()
                        }
                        return nil
                    }

                    // Enter key (36) or Numpad enter (76) triggers replace directly
                    if TranslateMonitor.isHudVisible && (keyCode == 36 || keyCode == 76) {
                        DispatchQueue.main.async {
                            TranslationHudController.shared.triggerReplaceFromEnterKey()
                        }
                        return nil
                    }

                    // Match target shortcut
                    if !m.isRightClickMode && keyCode == m.targetKeyCode {
                        let hasCmd = keyFlags.contains(.maskCommand)
                        let hasAlt = keyFlags.contains(.maskAlternate)
                        let hasCtrl = keyFlags.contains(.maskControl)
                        let hasShift = keyFlags.contains(.maskShift)

                        if hasCmd == m.requireCmd && hasAlt == m.requireAlt && hasCtrl == m.requireCtrl && hasShift == m.requireShift {
                            // Plain key pressed mid-typing (e.g. Space committing an IME composition): no new
                            // selection is possible, so never intercept it.
                            if m.isSingleKeyMode && wasTyping {
                                return Unmanaged.passUnretained(event)
                            }
                            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                                return Unmanaged.passUnretained(event)
                            }
                            let name = frontApp.localizedName?.lowercased() ?? ""
                            let bundleId = frontApp.bundleIdentifier?.lowercased() ?? ""

                            // Ignore self or designated applications
                            var shouldIgnore = false
                            if !bundleId.isEmpty && m.cachedIgnoredBundleIds.contains(bundleId) {
                                shouldIgnore = true
                            }
                            if let curId = Bundle.main.bundleIdentifier?.lowercased(), !curId.isEmpty && bundleId == curId {
                                shouldIgnore = true
                            }
                            for kw in m.cachedIgnoredKeywords {
                                if name.contains(kw) {
                                    shouldIgnore = true
                                    break
                                }
                            }

                            if shouldIgnore {
                                return Unmanaged.passUnretained(event)
                            }

                            // If already detecting, pass through immediately to avoid typing lag
                            if TranslateMonitor.shared.isDetecting {
                                return Unmanaged.passUnretained(event)
                            }

                            TranslateMonitor.shared.handleTrigger(shouldReplay: true)
                            return nil // Intercept native shortcut
                        }
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            print("Failed to create translate event tap")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.isMonitoring = true
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        self.eventTap = nil
        self.runLoopSource = nil
        self.isMonitoring = false
    }

    public struct AXSelectionInfo {
        public let text: String?
        public let isZeroLengthCaret: Bool
        public let isEditableField: Bool
        public let hasDefiniteSelection: Bool
    }

    /// Upper bound for a single AX round-trip (system default is ~6s, which would stall a hung app's trigger)
    private static let axMessagingTimeout: Float = 0.25

    private static let axPidLock = NSLock()
    nonisolated(unsafe) private static var axPreparedPids: Set<pid_t> = []

    /// Electron (and other lazy-AX apps honoring it) only expose their AX tree once an assistive client asks.
    /// `AXManualAccessibility` is side-effect free, and apps that don't support it simply reject the write,
    /// so it's applied to every app once per pid. `AXEnhancedUserInterface` is deliberately NOT used:
    /// it breaks window animations / window managers.
    private static func enableLazyAccessibilityIfNeeded(app: AXUIElement, pid: pid_t) {
        guard pid > 0 else { return }
        axPidLock.lock()
        let alreadyPrepared = !axPreparedPids.insert(pid).inserted
        if axPreparedPids.count > 256 { axPreparedPids = [pid] }
        axPidLock.unlock()
        guard !alreadyPrepared else { return }

        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Synchronously query currently focused UI element for selected text via macOS Accessibility API (< 1ms)
    public static func getSelectedTextViaAccessibility(frontPid: pid_t = 0) -> AXSelectionInfo {
        var appElement: AXUIElement?
        if frontPid > 0 {
            appElement = AXUIElementCreateApplication(frontPid)
        } else if let front = NSWorkspace.shared.frontmostApplication {
            appElement = AXUIElementCreateApplication(front.processIdentifier)
        }

        if let app = appElement {
            AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
            enableLazyAccessibilityIfNeeded(app: app, pid: frontPid > 0 ? frontPid : (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0))
        }

        var focusedElementVal: AnyObject?
        var gotFocusedElement = false

        // 1. First attempt: get focused element directly from front application
        if let app = appElement {
            let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElementVal)
            if err == .success, focusedElementVal != nil {
                gotFocusedElement = true
            } else if err == .cannotComplete {
                // App is hung / not answering within the timeout: don't stack further blocking queries
                axLogger.debug("AX query timed out for pid \(frontPid)")
                return AXSelectionInfo(text: nil, isZeroLengthCaret: false, isEditableField: false, hasDefiniteSelection: false)
            }
        }

        // 2. Second attempt: get focused window from front application -> focused element inside window
        var focusedWindowElement: AXUIElement?
        if let app = appElement {
            var focusedWindowVal: AnyObject?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindowVal) == .success,
               let win = focusedWindowVal, CFGetTypeID(win) == AXUIElementGetTypeID() {
                let winEl = win as! AXUIElement
                focusedWindowElement = winEl
                if !gotFocusedElement {
                    if AXUIElementCopyAttributeValue(winEl, kAXFocusedUIElementAttribute as CFString, &focusedElementVal) == .success,
                       focusedElementVal != nil {
                        gotFocusedElement = true
                    }
                }
            }
        }

        // 3. Third attempt: systemWide focused element
        if !gotFocusedElement {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementVal) == .success,
               focusedElementVal != nil {
                gotFocusedElement = true
            }
        }

        // 4. Readiness wait: If Electron/Chromium is cold and building its tree in background, wait up to 30ms (2x 15ms)
        var retry = 0
        while !gotFocusedElement && retry < 2, let app = appElement {
            usleep(15_000)
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElementVal) == .success,
               focusedElementVal != nil {
                gotFocusedElement = true
                break
            }
            if let win = focusedWindowElement {
                if AXUIElementCopyAttributeValue(win, kAXFocusedUIElementAttribute as CFString, &focusedElementVal) == .success,
                   focusedElementVal != nil {
                    gotFocusedElement = true
                    break
                }
            }
            retry += 1
        }

        var isEditable = false
        var hasDefiniteSelection = false
        var isZeroLengthCaret = false
        var selectedText: String? = nil

        if gotFocusedElement, let focusedElement = focusedElementVal {
            let element = focusedElement as! AXUIElement

            // Check if element is an editable text input field (TextField, TextArea, SearchField, ComboBox, or editable text)
            var roleVal: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal) == .success,
               let role = roleVal as? String {
                let lower = role.lowercased()
                if lower.contains("textfield") || lower.contains("textarea") || lower.contains("searchfield") || lower.contains("combobox") {
                    isEditable = true
                }
            }

            // Also check role description (Chromium often reports role description as "editable text")
            var roleDescVal: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDescVal) == .success,
               let roleDesc = roleDescVal as? String {
                if roleDesc.lowercased().contains("edit") {
                    isEditable = true
                }
            }

            // Check if kAXValueAttribute is settable (standard for all editable fields)
            var isSettable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable) == .success,
               isSettable.boolValue {
                isEditable = true
            }

            // Check if element has an editable ancestor (Chromium web inputs)
            var editableAncestorVal: AnyObject?
            if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editableAncestorVal) == .success,
               editableAncestorVal != nil {
                isEditable = true
            }

            // Direct selected text check (mouse drag, Cmd+A, Shift+Arrow)
            var selectedTextVal: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextVal) == .success,
               let str = selectedTextVal as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    selectedText = trimmed
                    hasDefiniteSelection = true
                }
            }

            // Caret range check (CFRange)
            var selectedRangeVal: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeVal) == .success,
               CFGetTypeID(selectedRangeVal) == AXValueGetTypeID() {
                let axVal = selectedRangeVal as! AXValue
                var range = CFRange()
                if AXValueGetValue(axVal, .cfRange, &range) {
                    if range.length > 0 {
                        hasDefiniteSelection = true
                        if selectedText == nil {
                            var paramVal: AnyObject?
                            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, axVal, &paramVal) == .success,
                               let pStr = paramVal as? String {
                                let trimmed = pStr.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    selectedText = trimmed
                                }
                            }
                        }
                    } else {
                        // Length == 0: blinking caret in an input box without selection
                        isZeroLengthCaret = true
                        isEditable = true
                    }
                }
            }
        }

        // Also check window-level selected text if element didn't yield text (Chromium / WebKit web pages)
        if selectedText == nil, let win = focusedWindowElement {
            var winSelVal: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXSelectedTextAttribute as CFString, &winSelVal) == .success,
               let wStr = winSelVal as? String {
                let trimmed = wStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    selectedText = trimmed
                    hasDefiniteSelection = true
                }
            }
        }

        var debugRole = "nil"
        if gotFocusedElement, let elVal = focusedElementVal, CFGetTypeID(elVal) == AXUIElementGetTypeID() {
            let el = elVal as! AXUIElement
            var r: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success,
               let roleStr = r as? String {
                debugRole = roleStr
            }
        }

        axLogger.debug("gotEl: \(gotFocusedElement), role: \(debugRole, privacy: .public), isEditable: \(isEditable), hasDefSel: \(hasDefiniteSelection), isCaret0: \(isZeroLengthCaret), selText: \(selectedText ?? "nil", privacy: .private)")

        return AXSelectionInfo(
            text: selectedText,
            isZeroLengthCaret: isZeroLengthCaret,
            isEditableField: isEditable,
            hasDefiniteSelection: hasDefiniteSelection
        )
    }

    private var lastText: String = ""
    private var lastFrontPid: pid_t = 0
    private var lastForcedDirection: String? = nil

    public func cancelCurrentTranslation() {
        currentTranslationTask?.cancel()
        currentTranslationTask = nil
    }

    @MainActor
    public func toggleDirectionAndRetranslate() {
        guard !lastText.isEmpty else { return }
        let currentDirection = TranslationHudController.shared.model.direction
        let newDirection = (currentDirection == "ZH ➔ EN") ? "EN ➔ ZH" : "ZH ➔ EN"
        triggerDirectTranslation(text: lastText, frontPid: lastFrontPid, forcedDirection: newDirection)
    }

    public func retryTranslation() {
        guard !lastText.isEmpty else { return }
        triggerDirectTranslation(text: lastText, frontPid: lastFrontPid, forcedDirection: lastForcedDirection)
    }

    public func triggerDirectTranslation(text: String, frontPid: pid_t, forcedDirection: String? = nil) {
        lastText = text
        lastFrontPid = frontPid
        lastForcedDirection = forcedDirection
        currentTranslationTask?.cancel()

        // 1. Immediately show Loading HUD on MainActor (0ms feedback!)
        DispatchQueue.main.async {
            TranslationHudController.shared.showLoading(original: text, targetPid: frontPid, forcedDirection: forcedDirection)
        }

        currentTranslationTask = Task {
            let provider = await SwaprTransConfig.shared.provider
            // On macOS 15+, Apple Native Translation is handled directly by AppleTranslationModifier in TranslationHudView
            if #available(macOS 15.0, *), provider == .apple {
                return
            }

            do {
                let res = try await TranslationEngine.shared.translate(text: text, provider: provider, forcedDirection: forcedDirection)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    TranslationHudController.shared.updateTranslation(
                        translated: res.result,
                        direction: res.direction,
                        provider: res.actualProvider
                    )
                    SwaprTransConfig.shared.log("[Translation (\(res.actualProvider))] \"\(text.prefix(20))...\" ➔ \"\(res.result.prefix(20))...\"", level: .info)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    TranslationHudController.shared.showError(message: error.localizedDescription)
                    SwaprTransConfig.shared.log("Translation failed: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }

    private func handleTrigger(shouldReplay: Bool) {
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        // TIS APIs must run on the main thread; the tap callback is on the main run loop
        copyKeyCode = Self.resolveCommandKeyCode(for: "c") ?? Self.ansiCKeyCode
        triggerSelectionTranslation(frontPid: frontPid, shouldReplay: shouldReplay)
    }

    private static let ansiCKeyCode: CGKeyCode = 0x08
    private var copyKeyCode: CGKeyCode = TranslateMonitor.ansiCKeyCode

    /// Find the virtual key producing `character` while ⌘ is held in the current keyboard layout
    /// (handles Dvorak/AZERTY and "Dvorak - QWERTY ⌘"; IMEs report their underlying ASCII layout).
    private static func resolveCommandKeyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        let modifierState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifierState,
                                            keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let items = (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
        return PasteboardSnapshot(items: items)
    }

    private static func restorePasteboard(_ pb: NSPasteboard, from snapshot: PasteboardSnapshot) {
        pb.clearContents()
        let items = snapshot.items.compactMap { entry -> NSPasteboardItem? in
            guard !entry.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pb.writeObjects(items)
        }
    }

    private func triggerSelectionTranslation(frontPid: pid_t, shouldReplay: Bool) {
        guard !isDetecting else { return }
        isDetecting = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            defer {
                self?.isDetecting = false
            }

            // 1. Try Accessibility API first (silent, zero pasteboard interference, no NSBeep)
            guard let monitor = self else { return }
            let axInfo = monitor.readSettledSelection(frontPid: frontPid)
            if let text = axInfo.text, !text.isEmpty {
                self?.triggerDirectTranslation(text: text, frontPid: frontPid)
                return
            }

            // 2. If in an editable input field and confirmed typing state (zero-length caret, or editable without definite selection):
            // User is 100% typing! Replay key directly and NEVER invoke simulateCmdC()!
            if axInfo.isZeroLengthCaret || (axInfo.isEditableField && !axInfo.hasDefiniteSelection) {
                if shouldReplay {
                    self?.replayTargetKey()
                }
                return
            }

            // 4. Fallback: only simulate Cmd+C when outside editable fields or non-standard views.
            // Snapshot the user's clipboard first and put it back afterwards.
            let pasteboard = NSPasteboard.general
            let snapshot = TranslateMonitor.snapshotPasteboard(pasteboard)
            let oldChangeCount = pasteboard.changeCount
            self?.simulateCmdC()

            let start = Date()
            var detectedNewText = false
            while Date().timeIntervalSince(start) < 0.10 {
                if pasteboard.changeCount != oldChangeCount {
                    detectedNewText = true
                    break
                }
                usleep(10_000)
            }

            var copiedText: String? = nil
            if detectedNewText {
                // Apps may clearContents() and write the string in separate steps; wait for the data to land
                // before restoring, otherwise the late write would clobber the restored clipboard.
                while true {
                    copiedText = pasteboard.string(forType: .string)
                    if copiedText != nil || Date().timeIntervalSince(start) > 0.20 { break }
                    usleep(10_000)
                }
                copiedText = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                TranslateMonitor.restorePasteboard(pasteboard, from: snapshot)
            }

            if let text = copiedText, !text.isEmpty {
                self?.triggerDirectTranslation(text: text, frontPid: frontPid)
                return
            }

            // If no text selected, replay native key to avoid dropping key press
            if shouldReplay {
                self?.replayTargetKey()
            }
        }
    }

    private func readSettledSelection(frontPid: pid_t) -> AXSelectionInfo {
        var current = TranslateMonitor.getSelectedTextViaAccessibility(frontPid: frontPid)
        let changedAt = lastSelectionChangeUptime
        let now = { ProcessInfo.processInfo.systemUptime }
        guard now() - changedAt < Self.selectionSettleWindow else { return current }

        // Require the settle window to elapse and two consecutive identical reads
        while now() - changedAt < Self.selectionSettleHardCap {
            usleep(Self.selectionPollIntervalUs)
            let next = TranslateMonitor.getSelectedTextViaAccessibility(frontPid: frontPid)
            let stable = next.text == current.text
                && next.hasDefiniteSelection == current.hasDefiniteSelection
                && next.isZeroLengthCaret == current.isZeroLengthCaret
            current = next
            if stable && now() - changedAt >= Self.selectionSettleWindow {
                break
            }
        }
        return current
    }

    private func simulateCmdC() {
        let src = CGEventSource(stateID: .hidSystemState)
        let modDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        modDown?.flags = .maskCommand

        let cKey = copyKeyCode
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        cDown?.flags = .maskCommand

        let cUp = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        cUp?.flags = .maskCommand

        let modUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        modUp?.flags = []

        modDown?.post(tap: .cghidEventTap)
        usleep(10_000)
        cDown?.post(tap: .cghidEventTap)
        usleep(15_000)
        cUp?.post(tap: .cghidEventTap)
        usleep(10_000)
        modUp?.post(tap: .cghidEventTap)
    }

    private func replayTargetKey() {
        isReplayingKey = true
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(targetKeyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(targetKeyCode), keyDown: false)

        var flag: CGEventFlags = []
        if requireCmd { flag.insert(.maskCommand) }
        if requireAlt { flag.insert(.maskAlternate) }
        if requireCtrl { flag.insert(.maskControl) }
        if requireShift { flag.insert(.maskShift) }
        down?.flags = flag
        up?.flags = flag

        down?.post(tap: .cghidEventTap)
        usleep(3_000)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isReplayingKey = false
        }
    }
}
