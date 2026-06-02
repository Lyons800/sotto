import AppKit
import Carbon.HIToolbox

/// C-style callback for the CGEvent tap. Can't capture context, so `self` is passed via
/// `userInfo` (refcon). The tap is session-level + listen-only, so it sees modifier events
/// reliably whether Murmur is in the background OR frontmost — unlike NSEvent monitors,
/// which miss events when the app has focus and drop them intermittently in the background.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables a tap if its callback is slow or after certain input; re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.reEnableTap()
        return Unmanaged.passUnretained(event)
    }

    if let nsEvent = NSEvent(cgEvent: event) {
        manager.handle(nsEvent, type: type)
    }
    return Unmanaged.passUnretained(event) // listen-only: never modify the event
}

final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isModifierKeyDown = false
    private var activeHoldIsCommand = false

    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    /// Fired when the dictation key is held together with ⇧ — Command Mode (Murmur Pro).
    var onCommandStart: (() -> Void)?
    var onCommandStop: (() -> Void)?

    private var targetKeyCode: UInt16
    private var targetModifiers: UInt
    private var mode: RecordingMode
    private var isToggled = false

    /// Test hook (internal; visible via @testable import).
    var hasEventTapForTesting: Bool { eventTap != nil }

    init(keyCode: UInt16 = UInt16(kVK_RightOption), modifiers: UInt = 0, mode: RecordingMode = .hold) {
        self.targetKeyCode = keyCode
        self.targetModifiers = modifiers
        self.mode = mode
    }

    func start() {
        stop()

        let isModifierKey = isModifierOnlyKey(targetKeyCode)
        let mask: CGEventMask = isModifierKey
            ? (1 << CGEventType.flagsChanged.rawValue)
            : ((1 << CGEventType.keyDown.rawValue)
               | (1 << CGEventType.keyUp.rawValue)
               | (1 << CGEventType.flagsChanged.rawValue)) // flags tracked for the modifier match

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: refcon
        ) else {
            NSLog("[Murmur] Hotkey event tap could not be created — grant Input Monitoring / Accessibility")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        isModifierKeyDown = false
        activeHoldIsCommand = false
        isToggled = false
    }

    func reEnableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func updateHotkey(keyCode: UInt16, modifiers: UInt = 0, mode: RecordingMode) {
        self.targetKeyCode = keyCode
        self.targetModifiers = modifiers
        self.mode = mode
        start() // Restart the tap with new config
    }

    // MARK: - Event Handling

    /// Routes a tap event (converted to NSEvent) to the right handler.
    func handle(_ event: NSEvent, type: CGEventType) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown, .keyUp:
            handleKeyEvent(event)
        default:
            break
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard event.keyCode == targetKeyCode else { return }

        // Check modifiers match (mask out device-dependent bits)
        let currentMods = event.modifierFlags.rawValue & 0x00FF0000
        guard currentMods == targetModifiers || targetModifiers == 0 else { return }

        switch mode {
        case .hold:
            if event.type == .keyDown && !event.isARepeat {
                onRecordingStart?()
            } else if event.type == .keyUp {
                onRecordingStop?()
            }
        case .toggle:
            if event.type == .keyDown && !event.isARepeat {
                isToggled.toggle()
                if isToggled {
                    onRecordingStart?()
                } else {
                    onRecordingStop?()
                }
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isPressed = isTargetModifierPressed(event)

        switch mode {
        case .hold:
            if isPressed && !isModifierKeyDown {
                isModifierKeyDown = true
                // ⇧ held together with the dictation key = Command Mode (Murmur Pro).
                activeHoldIsCommand = event.modifierFlags.contains(.shift)
                if activeHoldIsCommand { onCommandStart?() } else { onRecordingStart?() }
            } else if !isPressed && isModifierKeyDown {
                isModifierKeyDown = false
                if activeHoldIsCommand { onCommandStop?() } else { onRecordingStop?() }
                activeHoldIsCommand = false
            }
        case .toggle:
            if isPressed && !isModifierKeyDown {
                isModifierKeyDown = true
                isToggled.toggle()
                if isToggled {
                    onRecordingStart?()
                } else {
                    onRecordingStop?()
                }
            } else if !isPressed {
                isModifierKeyDown = false
            }
        }
    }

    // Device-specific modifier bit masks (from IOKit NX_* constants)
    private static let rightOptionMask:  UInt = 0x40
    private static let leftOptionMask:   UInt = 0x20
    private static let rightCommandMask: UInt = 0x10
    private static let leftCommandMask:  UInt = 0x08
    private static let rightShiftMask:   UInt = 0x04
    private static let leftShiftMask:    UInt = 0x02
    private static let rightControlMask: UInt = 0x2000
    private static let leftControlMask:  UInt = 0x01

    private func isTargetModifierPressed(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        switch targetKeyCode {
        case UInt16(kVK_RightOption):
            return raw & Self.rightOptionMask != 0
        case UInt16(kVK_Option):
            return raw & Self.leftOptionMask != 0
        case UInt16(kVK_RightCommand):
            return raw & Self.rightCommandMask != 0
        case UInt16(kVK_Command):
            return raw & Self.leftCommandMask != 0
        case UInt16(kVK_RightShift):
            return raw & Self.rightShiftMask != 0
        case UInt16(kVK_Shift):
            return raw & Self.leftShiftMask != 0
        case UInt16(kVK_RightControl):
            return raw & Self.rightControlMask != 0
        case UInt16(kVK_Control):
            return raw & Self.leftControlMask != 0
        default:
            return false
        }
    }

    private func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        let modifierKeys: Set<UInt16> = [
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Shift), UInt16(kVK_RightShift),
            UInt16(kVK_Control), UInt16(kVK_RightControl),
        ]
        return modifierKeys.contains(keyCode)
    }
}
