import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import Geraldine

final class KeyboardPowerToolsReducerTests: XCTestCase {
    func testFileEffectCoordinatorSerializesQueuedEffectsInFIFOOrder() {
        var coordinator = KeyboardPowerToolsFileEffectCoordinator()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let first = coordinator.enqueue(.pasteCut, identifier: firstID)
        let second = coordinator.enqueue(.prepareCut, identifier: secondID)
        let third = coordinator.enqueue(.createTextFile, identifier: thirdID)

        XCTAssertEqual(first.identifier, firstID)
        XCTAssertEqual(first.effect, .pasteCut)
        XCTAssertEqual(coordinator.ownership, first)
        XCTAssertTrue(coordinator.isActive(first))
        XCTAssertFalse(coordinator.isActive(second))
        XCTAssertEqual(coordinator.queuedEffects, [.prepareCut, .createTextFile])

        XCTAssertEqual(coordinator.complete(first), second)
        XCTAssertEqual(coordinator.ownership, second)
        XCTAssertEqual(coordinator.queuedEffects, [.createTextFile])
        XCTAssertNil(coordinator.complete(first))
        XCTAssertEqual(coordinator.ownership, second)

        XCTAssertEqual(coordinator.complete(second), third)
        XCTAssertEqual(coordinator.ownership, third)
        XCTAssertEqual(coordinator.queuedEffects, [])
        XCTAssertNil(coordinator.complete(third))
        XCTAssertNil(coordinator.ownership)
    }

    func testFileEffectCoordinatorInvalidationRejectsStaleCompletion() {
        var coordinator = KeyboardPowerToolsFileEffectCoordinator()
        let first = coordinator.enqueue(
            .pasteCut,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        _ = coordinator.enqueue(
            .prepareCut,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        coordinator.invalidate()
        XCTAssertNil(coordinator.ownership)
        XCTAssertEqual(coordinator.queuedEffects, [])

        let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let current = coordinator.enqueue(.createTextFile, identifier: currentID)
        XCTAssertNil(coordinator.complete(first))
        XCTAssertEqual(coordinator.ownership, current)

        XCTAssertNil(coordinator.complete(current))
        XCTAssertNil(coordinator.ownership)
        let reacquired = coordinator.enqueue(
            .moveFinderSelectionToTrash,
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )
        XCTAssertEqual(reacquired.effect, .moveFinderSelectionToTrash)
    }

    private func preferences(
        commandQ: Bool = true,
        commandW: Bool = true,
        finderReturn: Bool = true,
        finderCutPaste: Bool = true,
        finderOptionN: Bool = true,
        finderBackspace: Bool = true
    ) -> KeyboardPowerToolsPreferences {
        KeyboardPowerToolsPreferences(
            commandQDoubleTap: commandQ,
            commandWDoubleTap: commandW,
            finderReturnOpens: finderReturn,
            finderCutPaste: finderCutPaste,
            finderOptionNNewFile: finderOptionN,
            finderBackspaceMovesToTrash: finderBackspace
        )
    }

    private func input(
        keyCode: Int64,
        modifiers: KeyboardPowerToolsModifiers = [],
        autorepeat: Bool = false,
        timestamp: TimeInterval = 0,
        processIdentifier: pid_t? = 42,
        bundleIdentifier: String? = "com.apple.finder",
        finderCanHandle: Bool = true,
        hasCutSession: Bool = false
    ) -> KeyboardPowerToolsInput {
        KeyboardPowerToolsInput(
            keyCode: keyCode,
            modifiers: modifiers,
            isAutorepeat: autorepeat,
            timestamp: timestamp,
            frontmostProcessIdentifier: processIdentifier,
            frontmostBundleIdentifier: bundleIdentifier,
            finderCanHandleFileShortcut: finderCanHandle,
            hasFinderCutSession: hasCutSession
        )
    }

    func testDoubleTapTimingBoundariesAndNilProcessBucket() {
        let enabled = preferences()

        var accepted = KeyboardPowerToolsReducer()
        XCTAssertEqual(
            accepted.reduce(
                input: input(keyCode: KeyboardPowerToolsKeyCode.q, modifiers: .command, timestamp: 0),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
        XCTAssertEqual(
            accepted.reduce(
                input: input(keyCode: KeyboardPowerToolsKeyCode.q, modifiers: .command, timestamp: 1.149),
                preferences: enabled
            ),
            .pass
        )
        XCTAssertEqual(accepted.pendingSafetyPressCount, 0)

        var exactAcceptanceBoundary = KeyboardPowerToolsReducer()
        _ = exactAcceptanceBoundary.reduce(
            input: input(keyCode: KeyboardPowerToolsKeyCode.q, modifiers: .command, timestamp: 0),
            preferences: enabled
        )
        XCTAssertEqual(
            exactAcceptanceBoundary.reduce(
                input: input(keyCode: KeyboardPowerToolsKeyCode.q, modifiers: .command, timestamp: 1.15),
                preferences: enabled
            ),
            .suppressing(.beep)
        )

        var retained = KeyboardPowerToolsReducer()
        _ = retained.reduce(
            input: input(
                keyCode: KeyboardPowerToolsKeyCode.q,
                modifiers: .command,
                timestamp: 0,
                processIdentifier: 10
            ),
            preferences: enabled
        )
        _ = retained.reduce(
            input: input(
                keyCode: KeyboardPowerToolsKeyCode.w,
                modifiers: .command,
                timestamp: 1.999,
                processIdentifier: 20
            ),
            preferences: enabled
        )
        XCTAssertEqual(retained.pendingSafetyPressCount, 2)

        var pruned = KeyboardPowerToolsReducer()
        _ = pruned.reduce(
            input: input(
                keyCode: KeyboardPowerToolsKeyCode.q,
                modifiers: .command,
                timestamp: 0,
                processIdentifier: 10
            ),
            preferences: enabled
        )
        _ = pruned.reduce(
            input: input(
                keyCode: KeyboardPowerToolsKeyCode.w,
                modifiers: .command,
                timestamp: 2.0,
                processIdentifier: 20
            ),
            preferences: enabled
        )
        XCTAssertEqual(pruned.pendingSafetyPressCount, 1)

        var expired = KeyboardPowerToolsReducer()
        _ = expired.reduce(
            input: input(keyCode: KeyboardPowerToolsKeyCode.q, modifiers: .command, timestamp: 0),
            preferences: enabled
        )
        XCTAssertEqual(
            expired.reduce(
                input: input(keyCode: KeyboardPowerToolsKeyCode.q, modifiers: .command, timestamp: 2.0),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
        XCTAssertEqual(expired.pendingSafetyPressCount, 1)

        var nilProcess = KeyboardPowerToolsReducer()
        XCTAssertEqual(
            nilProcess.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.w,
                    modifiers: .command,
                    timestamp: 10,
                    processIdentifier: nil,
                    bundleIdentifier: nil,
                    finderCanHandle: false
                ),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
        XCTAssertEqual(
            nilProcess.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.w,
                    modifiers: .command,
                    timestamp: 11,
                    processIdentifier: nil,
                    bundleIdentifier: nil,
                    finderCanHandle: false
                ),
                preferences: enabled
            ),
            .pass
        )

        var expiredW = KeyboardPowerToolsReducer()
        XCTAssertEqual(
            expiredW.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.w,
                    modifiers: .command,
                    timestamp: 20,
                    processIdentifier: 77
                ),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
        XCTAssertEqual(
            expiredW.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.w,
                    modifiers: .command,
                    timestamp: 21.2,
                    processIdentifier: 77
                ),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
    }

    func testSafetyKeysKeepPIDAndKeyIndependentAndResetState() {
        let enabled = preferences()
        var reducer = KeyboardPowerToolsReducer()

        XCTAssertEqual(
            reducer.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.q,
                    modifiers: .command,
                    timestamp: 0,
                    processIdentifier: 10
                ),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
        XCTAssertEqual(
            reducer.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.q,
                    modifiers: .command,
                    timestamp: 0.5,
                    processIdentifier: 20
                ),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
        XCTAssertEqual(
            reducer.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.w,
                    modifiers: .command,
                    timestamp: 0.75,
                    processIdentifier: 10
                ),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
        XCTAssertEqual(reducer.pendingSafetyPressCount, 3)

        let countBeforeAutorepeat = reducer.pendingSafetyPressCount
        XCTAssertEqual(
            reducer.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.q,
                    modifiers: .command,
                    autorepeat: true,
                    timestamp: 1,
                    processIdentifier: 10
                ),
                preferences: enabled
            ),
            .suppressing()
        )
        XCTAssertEqual(reducer.pendingSafetyPressCount, countBeforeAutorepeat)
        XCTAssertEqual(
            reducer.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.q,
                    modifiers: .command,
                    timestamp: 1.2,
                    processIdentifier: 10
                ),
                preferences: enabled
            ),
            .suppressing(.beep),
            "Autorepeat must not rewrite the original timestamp into the acceptance window."
        )
        XCTAssertEqual(reducer.pendingSafetyPressCount, countBeforeAutorepeat)

        reducer.reset()
        XCTAssertEqual(reducer.pendingSafetyPressCount, 0)
        XCTAssertEqual(
            reducer.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.q,
                    modifiers: .command,
                    timestamp: 1.1,
                    processIdentifier: 10
                ),
                preferences: enabled
            ),
            .suppressing(.beep)
        )
    }

    func testFinderDecisionTable() {
        struct Row {
            let name: String
            let input: KeyboardPowerToolsInput
            let preferences: KeyboardPowerToolsPreferences
            let expected: KeyboardPowerToolsDecision
        }

        let enabled = preferences()
        let disabled = preferences(
            commandQ: false,
            commandW: false,
            finderReturn: false,
            finderCutPaste: false,
            finderOptionN: false,
            finderBackspace: false
        )
        let rows = [
            Row(
                name: "Return opens",
                input: input(keyCode: KeyboardPowerToolsKeyCode.returnKey),
                preferences: enabled,
                expected: .suppressing(.openFinderSelection)
            ),
            Row(
                name: "Option-N creates text",
                input: input(keyCode: KeyboardPowerToolsKeyCode.n, modifiers: .option),
                preferences: enabled,
                expected: .suppressing(.createTextFile)
            ),
            Row(
                name: "Backspace trashes",
                input: input(keyCode: KeyboardPowerToolsKeyCode.delete),
                preferences: enabled,
                expected: .suppressing(.moveFinderSelectionToTrash)
            ),
            Row(
                name: "Command-X prepares cut",
                input: input(keyCode: KeyboardPowerToolsKeyCode.x, modifiers: .command),
                preferences: enabled,
                expected: .suppressing(.prepareCut)
            ),
            Row(
                name: "Command-V pastes cut",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.v,
                    modifiers: .command,
                    hasCutSession: true
                ),
                preferences: enabled,
                expected: .suppressing(.pasteCut)
            ),
            Row(
                name: "Command-V without cut passes",
                input: input(keyCode: KeyboardPowerToolsKeyCode.v, modifiers: .command),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Non-Finder passes",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.returnKey,
                    bundleIdentifier: "com.example.Editor"
                ),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Finder without file focus passes",
                input: input(keyCode: KeyboardPowerToolsKeyCode.returnKey, finderCanHandle: false),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Extra primary modifier rejects Option-N",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.n,
                    modifiers: [.option, .shift]
                ),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Extra primary modifier rejects Return",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.returnKey,
                    modifiers: .command
                ),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Extra primary modifier rejects Backspace",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.delete,
                    modifiers: .command
                ),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Extra primary modifier rejects Command-X",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.x,
                    modifiers: [.command, .shift]
                ),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Extra primary modifier rejects Command-V",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.v,
                    modifiers: [.command, .option],
                    hasCutSession: true
                ),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Unrelated key passes",
                input: input(keyCode: 8),
                preferences: enabled,
                expected: .pass
            ),
            Row(
                name: "Disabled Return passes",
                input: input(keyCode: KeyboardPowerToolsKeyCode.returnKey),
                preferences: disabled,
                expected: .pass
            ),
            Row(
                name: "Disabled Option-N passes",
                input: input(keyCode: KeyboardPowerToolsKeyCode.n, modifiers: .option),
                preferences: disabled,
                expected: .pass
            ),
            Row(
                name: "Disabled Backspace passes",
                input: input(keyCode: KeyboardPowerToolsKeyCode.delete),
                preferences: disabled,
                expected: .pass
            ),
            Row(
                name: "Disabled Command-X passes",
                input: input(keyCode: KeyboardPowerToolsKeyCode.x, modifiers: .command),
                preferences: disabled,
                expected: .pass
            ),
            Row(
                name: "Disabled Command-V passes",
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.v,
                    modifiers: .command,
                    hasCutSession: true
                ),
                preferences: disabled,
                expected: .pass
            ),
        ]

        for row in rows {
            var reducer = KeyboardPowerToolsReducer()
            XCTAssertEqual(
                reducer.reduce(input: row.input, preferences: row.preferences),
                row.expected,
                row.name
            )
        }
    }

    func testEveryHandledFinderAutorepeatSuppressesWithoutEffect() {
        let enabled = preferences()
        let inputs = [
            input(keyCode: KeyboardPowerToolsKeyCode.returnKey, autorepeat: true),
            input(keyCode: KeyboardPowerToolsKeyCode.n, modifiers: .option, autorepeat: true),
            input(keyCode: KeyboardPowerToolsKeyCode.delete, autorepeat: true),
            input(keyCode: KeyboardPowerToolsKeyCode.x, modifiers: .command, autorepeat: true),
            input(
                keyCode: KeyboardPowerToolsKeyCode.v,
                modifiers: .command,
                autorepeat: true,
                hasCutSession: true
            ),
        ]

        for handledInput in inputs {
            var reducer = KeyboardPowerToolsReducer()
            XCTAssertEqual(
                reducer.reduce(input: handledInput, preferences: enabled),
                .suppressing()
            )
        }
    }

    func testDisabledSafetyPreferencesAndExtraPrimaryModifiersPass() {
        var reducer = KeyboardPowerToolsReducer()
        XCTAssertEqual(
            reducer.reduce(
                input: input(keyCode: KeyboardPowerToolsKeyCode.q, modifiers: .command),
                preferences: preferences(commandQ: false)
            ),
            .pass
        )
        XCTAssertEqual(
            reducer.reduce(
                input: input(
                    keyCode: KeyboardPowerToolsKeyCode.w,
                    modifiers: [.command, .control]
                ),
                preferences: preferences()
            ),
            .pass
        )
        XCTAssertEqual(
            reducer.reduce(
                input: input(keyCode: KeyboardPowerToolsKeyCode.w, modifiers: .command),
                preferences: preferences(commandW: false)
            ),
            .pass
        )
        XCTAssertEqual(reducer.pendingSafetyPressCount, 0)
    }

    func testModifierNormalizationIgnoresNonPrimaryFlags() {
        let ignored: CGEventFlags = [.maskAlphaShift, .maskNumericPad, .maskSecondaryFn]

        XCTAssertEqual(KeyboardPowerToolsModifiers.normalized(from: ignored), [])
        XCTAssertEqual(
            KeyboardPowerToolsModifiers.normalized(from: ignored.union(.maskCommand)),
            .command
        )
        XCTAssertEqual(
            KeyboardPowerToolsModifiers.normalized(from: ignored.union(.maskAlternate)),
            .option
        )
        XCTAssertEqual(
            KeyboardPowerToolsModifiers.normalized(
                from: [.maskCommand, .maskShift, .maskControl, .maskAlternate]
            ),
            [.command, .shift, .control, .option]
        )
    }
}
