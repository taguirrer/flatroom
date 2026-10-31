import AppKit
import ApplicationServices

/// Intercepts the keyboard's volume up/down/mute keys while `shouldHandle` returns true and
/// reports them through `onKey`; otherwise the keys reach macOS untouched.
/// Needs the Accessibility permission (an event tap that can swallow events).
final class VolumeKeys {
    enum Key { case up, down, mute }

    var shouldHandle: () -> Bool = { false }
    /// `fine` is true with Option+Shift held (quarter steps, like macOS).
    var onKey: (Key, _ fine: Bool) -> Void = { _, _ in }

    private var tap: CFMachPort?
    private var retryTimer: Timer?

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private static let soundUp = 0, soundDown = 1, mute = 7

    /// Installs the tap now if allowed, otherwise asks for Accessibility and retries until granted.
    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), install() { return }
        Log.write("volume keys: waiting for Accessibility permission")
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.install() else { return }
            timer.invalidate()
        }
    }

    private func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED: media keys arrive as system-defined events
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: VolumeKeys.callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        Log.write("volume keys: active")
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        let keys = Unmanaged<VolumeKeys>.fromOpaque(userInfo!).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = keys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let key: Key
        switch code {
        case soundUp: key = .up
        case soundDown: key = .down
        case mute: key = .mute
        default: return Unmanaged.passUnretained(event)
        }
        guard keys.shouldHandle() else { return Unmanaged.passUnretained(event) }
        if isDown {
            let fine = ns.modifierFlags.contains([.option, .shift])
            keys.onKey(key, fine)
        }
        return nil  // swallow both key down and key up so macOS doesn't show its "unavailable" HUD
    }
}
