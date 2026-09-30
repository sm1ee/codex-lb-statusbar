import Carbon.HIToolbox
import Foundation

/// System-wide ⌥⌘L via Carbon `RegisterEventHotKey`. Unlike event taps, this needs no
/// Accessibility permission. Unregistered when the instance is released.
@MainActor
final class GlobalHotKey {
    static let displayString = "⌥⌘L"

    // Only touched on the main actor in init; deinit just releases them (isolated deinit needs a newer runtime).
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_L), modifiers: UInt32 = UInt32(optionKey | cmdKey), action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    hotKey.action()
                }
            }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        guard installed == noErr else {
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x434C_4253), id: 1) // "CLBS"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef {
                RemoveEventHandler(handlerRef)
            }
            return nil
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
