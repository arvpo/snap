import Carbon
@testable import SnapCore

@MainActor
func registerGlobalHotKeyTests() {
    test("shortcut is Command-Shift-X") {
        try expectEqual(SnapHotKey.keyCode, UInt32(kVK_ANSI_X))
        try expectEqual(SnapHotKey.carbonModifiers, UInt32(cmdKey | shiftKey))
        try expectEqual(SnapHotKey.signature, OSType(0x534E_4150))
    }
}
