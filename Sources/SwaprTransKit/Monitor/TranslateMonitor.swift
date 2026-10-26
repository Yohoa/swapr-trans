import Foundation
import Cocoa
import CoreGraphics

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
                    if !TranslateMonitor.shared.isRightClickMode && keyCode == TranslateMonitor.shared.targetKeyCode {
                        let flags = event.flags
                        let hasCmd = flags.contains(.maskCommand)
                        let hasAlt = flags.contains(.maskAlternate)
                        let hasCtrl = flags.contains(.maskControl)
                        let hasShift = flags.contains(.maskShift)

                        let m = TranslateMonitor.shared
                        if hasCmd == m.requireCmd && hasAlt == m.requireAlt && hasCtrl == m.requireCtrl && hasShift == m.requireShift {
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

    /// Synchronously query currently focused UI element for selected text via macOS Accessibility API (< 1ms)
    public static func getSelectedTextViaAccessibility(frontPid: pid_t = 0) -> AXSelectionInfo {
        var appElement: AXUIElement?
        if frontPid > 0 {
            appElement = AXUIElementCreateApplication(frontPid)
        } else if let front = NSWorkspace.shared.frontmostApplication {
            appElement = AXUIElementCreateApplication(front.processIdentifier)
        }

        if let app = appElement {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
        }

        var focusedElementVal: AnyObject?
        var gotFocusedElement = false

        // 1. First attempt: get focused element directly from front application
        if let app = appElement {
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElementVal) == .success,
               focusedElementVal != nil {
                gotFocusedElement = true
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

        NSLog("[SwaprTrans-DEBUG] gotEl: %d, role: %@, isEditable: %d, hasDefSel: %d, isCaret0: %d, selText: %@",
              gotFocusedElement ? 1 : 0,
              debugRole,
              isEditable ? 1 : 0,
              hasDefiniteSelection ? 1 : 0,
              isZeroLengthCaret ? 1 : 0,
              selectedText ?? "nil"
        )

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
        triggerSelectionTranslation(frontPid: frontPid, shouldReplay: shouldReplay)
    }

    private func triggerSelectionTranslation(frontPid: pid_t, shouldReplay: Bool) {
        guard !isDetecting else { return }
        isDetecting = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            defer {
                self?.isDetecting = false
            }

            // 1. Try Accessibility API first (silent, zero pasteboard interference, no NSBeep)
            let axInfo = TranslateMonitor.getSelectedTextViaAccessibility(frontPid: frontPid)
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

            // 4. Fallback: only simulate Cmd+C when outside editable fields or non-standard views
            let oldChangeCount = NSPasteboard.general.changeCount
            self?.simulateCmdC()

            let start = Date()
            var detectedNewText = false
            while Date().timeIntervalSince(start) < 0.10 {
                if NSPasteboard.general.changeCount != oldChangeCount {
                    detectedNewText = true
                    break
                }
                usleep(10_000)
            }

            if detectedNewText, let rawStr = NSPasteboard.general.string(forType: .string) {
                let trimmed = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.triggerDirectTranslation(text: trimmed, frontPid: frontPid)
                    return
                }
            }

            // If no text selected, replay native key to avoid dropping key press
            if shouldReplay {
                self?.replayTargetKey()
            }
        }
    }

    private func simulateCmdC() {
        let src = CGEventSource(stateID: .hidSystemState)
        let modDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        modDown?.flags = .maskCommand

        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        cDown?.flags = .maskCommand

        let cUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
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
