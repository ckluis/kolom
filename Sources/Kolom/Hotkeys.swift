import AppKit
import Carbon
final class Hotkeys {
    var refs: [EventHotKeyRef] = []
    var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    var failures: [String] = []
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard status == noErr else { return status }
                Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().action?(key.id)
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register() {
        unregister()
        failures = []
        let keys: [(UInt32, UInt32, UInt32, String)] = [
            (1, UInt32(kVK_LeftArrow), UInt32(optionKey), "Option Left"),
            (2, UInt32(kVK_RightArrow), UInt32(optionKey), "Option Right"),
            (3, UInt32(kVK_ANSI_M), UInt32(optionKey), "Option M"),
            (4, UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), "Control Option K"),
            (6, UInt32(kVK_ANSI_K), UInt32(optionKey), "Option K"),
        ]
        let digits = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        let bindings =
            keys + [(5, UInt32(kVK_ANSI_D), UInt32(optionKey), "Option D")]
            + digits.enumerated().map {
                (UInt32($0.offset + 10), UInt32($0.element), UInt32(optionKey), "Option \($0.offset+1)")
            }
        for (id, key, mods, label) in bindings {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(
                key, mods, EventHotKeyID(signature: 0x4B4F4C4D, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) } else { failures.append(label) }
        }
    }
    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}
