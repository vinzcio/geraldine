import CoreGraphics

enum DisplaySleepState {
    /// Active displays exclude sleeping displays. Query every online display,
    /// including hardware mirrors, before deciding that nothing is visible.
    /// A failed or empty query is unknown; callers keep monitoring in that case.
    static func read(
        onlineDisplays: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError = {
            CGGetOnlineDisplayList($0, $1, $2)
        },
        isAsleep: (CGDirectDisplayID) -> Bool = { CGDisplayIsAsleep($0) != 0 }
    ) -> Bool? {
        var count: UInt32 = 0
        guard onlineDisplays(0, nil, &count) == .success, count > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(count))
        var returnedCount: UInt32 = 0
        guard onlineDisplays(count, &displays, &returnedCount) == .success,
              returnedCount > 0, returnedCount <= count else { return nil }

        return displays.prefix(Int(returnedCount)).allSatisfy(isAsleep)
    }
}
