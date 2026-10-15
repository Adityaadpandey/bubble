import Carbon

// A system-wide shortcut through Carbon's RegisterEventHotKey, which (unlike a key event tap)
// needs no Accessibility permission. Example: HotKey(keyCode: 49, modifiers: controlKey | optionKey) { … } is ⌃⌥Space.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let fire: () -> Void

    init(keyCode: Int, modifiers: Int, _ fire: @escaping () -> Void) {
        self.fire = fire
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            Unmanaged<HotKey>.fromOpaque(me!).takeUnretainedValue().fire()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4E4F5449), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    // the handler holds a pointer to this object, so it goes first or the next press would call into freed memory
    deinit {
        ref.map { _ = UnregisterEventHotKey($0) }
        handler.map { _ = RemoveEventHandler($0) }
    }
}

// The shortcuts Settings offers, by the id it stores. "off" has no entry, so nothing gets registered.
enum Shortcut {
    static let choices: [(id: String, label: String, keyCode: Int, modifiers: Int)] = [
        ("ctrlOptSpace", "⌃⌥Space", 49, controlKey | optionKey),
        ("ctrlOptN", "⌃⌥N", 45, controlKey | optionKey),
        ("ctrlOptCmdSpace", "⌃⌥⌘Space", 49, controlKey | optionKey | cmdKey),
    ]
    static func hotKey(_ id: String, _ fire: @escaping () -> Void) -> HotKey? {
        choices.first { $0.id == id }.map { HotKey(keyCode: $0.keyCode, modifiers: $0.modifiers, fire) }
    }
}
