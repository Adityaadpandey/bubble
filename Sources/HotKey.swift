import Carbon

// A system-wide shortcut through Carbon's RegisterEventHotKey, which (unlike a key event tap)
// needs no Accessibility permission. Example: HotKey(keyCode: 49, modifiers: controlKey | optionKey) { … } is ⌃⌥Space.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let fire: () -> Void

    init(keyCode: Int, modifiers: Int, _ fire: @escaping () -> Void) {
        self.fire = fire
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            Unmanaged<HotKey>.fromOpaque(me!).takeUnretainedValue().fire()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4E4F5449), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
