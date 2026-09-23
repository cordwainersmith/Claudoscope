import AppKit
import Carbon.HIToolbox

/// System-wide shortcut that jumps to the oldest waiting agent. Uses Carbon's
/// RegisterEventHotKey, which works for a hardened-runtime menu bar app
/// without Accessibility permission (unlike NSEvent global monitors).
///
/// Default chord: Control+Option+Command+J. Off by default.
@MainActor @Observable
final class GlobalHotKeyService {
    static let enabledKey = "fleetJumpHotKeyEnabled"
    static let chordLabel = "\u{2303}\u{2325}\u{2318}J"

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { register() } else { unregister() }
        }
    }
    /// Non-nil when registration failed (usually a chord already taken).
    private(set) var registrationError: String?

    @ObservationIgnored var onTrigger: (() -> Void)?
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { register() }
    }

    /// Called from the Carbon trampoline on the main thread.
    fileprivate func fire() {
        onTrigger?()
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        registrationError = nil

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), hotKeyTrampoline, 1, &spec, userData, &handler)
        guard installStatus == noErr else {
            registrationError = "Could not install the shortcut handler (\(installStatus))."
            return
        }
        handlerRef = handler

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_J), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
        } else {
            registrationError = "The shortcut \(Self.chordLabel) is taken by another app (\(status))."
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        registrationError = nil
    }

    private static let signature: OSType = {
        // "CLSC" as a four-char code.
        var code: OSType = 0
        for byte in "CLSC".utf8 { code = (code << 8) | OSType(byte) }
        return code
    }()
}

/// C-convention callback; Carbon calls it on the main thread. Recovers the
/// service from userData and hops through the main actor explicitly so the
/// compiler can check isolation.
private let hotKeyTrampoline: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in service.fire() }
    return noErr
}
