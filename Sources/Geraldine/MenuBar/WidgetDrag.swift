import AppKit
import SwiftUI

// MARK: - Pure reorder policy

/// Decides where an in-flight drag should stage the dragged tile, given the settled
/// grid geometry. Pure math over `WidgetGridMetrics` — no view or controller state —
/// so the live gesture, the 60 Hz drive timer, and unit tests all share one brain.
enum WidgetReorderPolicy {
    enum Decision: Equatable {
        case none
        /// `stageMove(dragged, toIndexOf: target)`: dragged takes the target's spot —
        /// landing after it when approaching from earlier, before it from later.
        case move(targetID: String)
        case moveToEnd
    }

    /// Spatial hysteresis: a slot only captures the tile once its center is this far
    /// inside, so grazing a boundary can't flip the order back and forth.
    static let hitInset: CGFloat = 10

    /// Temporal hysteresis: a decision must hold steady this long before it commits,
    /// so sweeping across the grid doesn't reorder every row on the way.
    static let dwell: TimeInterval = 0.12

    /// Where every tile will rest for `items` once animations settle.
    static func settledSlots(items: [WidgetItem],
                             heights: [String: CGFloat],
                             width: CGFloat) -> [WidgetGridMetrics.Slot] {
        let entries = items.map { item in
            WidgetGridMetrics.Entry(
                id: item.kind.id,
                span: item.size.span,
                naturalHeight: item.size == .large
                    ? (heights[item.kind.id] ?? WidgetGridMetrics.unitHeight)
                    : WidgetGridMetrics.unitHeight
            )
        }
        return WidgetGridMetrics.slots(for: entries, width: width)
    }

    /// The staged reorder (if any) for a floating tile centered at `center` (grid space).
    static func decision(center rawCenter: CGPoint,
                         draggedID: String,
                         items: [WidgetItem],
                         heights: [String: CGFloat],
                         width: CGFloat) -> Decision {
        guard items.count > 1,
              items.contains(where: { $0.kind.id == draggedID }) else { return .none }
        let slots = settledSlots(items: items, heights: heights, width: width)
        guard let first = slots.first, let last = slots.last else { return .none }

        // Clamp horizontally so dragging past the grid's left/right edges still
        // targets by row instead of going dead.
        let center = CGPoint(x: min(max(rawCenter.x, 0), width), y: rawCenter.y)

        // Above the grid: take the front. Stable without a convergence test — the
        // cursor stays above the grid after the move, and the guard below goes quiet
        // once the dragged tile is first.
        if center.y < first.frame.minY, first.id != draggedID {
            return .move(targetID: first.id)
        }

        // Beyond the last slot (below the grid, or trailing it within the last row).
        if last.id != draggedID,
           center.y > last.frame.maxY
            || (center.y > last.frame.minY && center.x > last.frame.maxX) {
            return .moveToEnd
        }

        // Inside another tile's settled slot — the ordinary swap. Only commit if the
        // center would rest inside the dragged tile's own slot afterwards (a fixed
        // point), so mixed-span swaps can't ping-pong.
        if let hit = slots.first(where: { slot in
            slot.id != draggedID && slot.frame.insetBy(dx: hitInset, dy: hitInset).contains(center)
        }) {
            let candidate = moved(items, draggedID: draggedID, toIndexOf: hit.id)
            guard converges(items: candidate, center: center, draggedID: draggedID,
                            heights: heights, width: width) else { return .none }
            return .move(targetID: hit.id)
        }

        // Empty trailing space in a partially filled row: drop after that row's last
        // tile. The cursor may sit deeper in the gap than the tile will land, so the
        // fixed-point test here is on the *decision*, not the cursor's resting slot:
        // the candidate layout must not immediately demand another move.
        if let gap = trailingGapTarget(center: center, draggedID: draggedID,
                                       items: items, slots: slots) {
            let candidate: [WidgetItem]
            switch gap {
            case .move(let targetID): candidate = moved(items, draggedID: draggedID, toIndexOf: targetID)
            case .moveToEnd: candidate = movedToEnd(items, draggedID: draggedID)
            case .none: return .none
            }
            let candidateSlots = settledSlots(items: candidate, heights: heights, width: width)
            let hitsAnotherTile = candidateSlots.contains { slot in
                slot.id != draggedID && slot.frame.insetBy(dx: hitInset, dy: hitInset).contains(center)
            }
            let retriggers = trailingGapTarget(center: center, draggedID: draggedID,
                                               items: candidate, slots: candidateSlots) != nil
            guard !hitsAnotherTile, !retriggers else { return .none }
            return gap
        }

        return .none
    }

    /// A decision for a center that sits in a row's empty trailing space.
    private static func trailingGapTarget(center: CGPoint,
                                          draggedID: String,
                                          items: [WidgetItem],
                                          slots: [WidgetGridMetrics.Slot]) -> Decision? {
        // Rows share exactly one frame band by construction.
        let row = slots.filter { $0.frame.minY <= center.y && center.y <= $0.frame.maxY }
        guard let rowLast = row.max(by: { $0.frame.maxX < $1.frame.maxX }),
              center.x > rowLast.frame.maxX + hitInset,
              rowLast.id != draggedID else { return nil }
        guard let draggedIndex = items.firstIndex(where: { $0.kind.id == draggedID }),
              let rowLastIndex = items.firstIndex(where: { $0.kind.id == rowLast.id }) else { return nil }

        if draggedIndex < rowLastIndex {
            // Taking the row-last's spot from earlier lands the tile right after it.
            return .move(targetID: rowLast.id)
        }
        let followerIndex = rowLastIndex + 1
        guard followerIndex < items.count else { return .moveToEnd }
        let follower = items[followerIndex]
        guard follower.kind.id != draggedID else { return nil }  // already in the gap
        // Taking the follower's spot from later lands the tile right before it —
        // immediately after the row's last tile.
        return .move(targetID: follower.kind.id)
    }

    /// The fixed-point test: in the candidate order, would the floating center sit
    /// inside the dragged tile's own predicted slot?
    private static func converges(items: [WidgetItem], center: CGPoint, draggedID: String,
                                  heights: [String: CGFloat], width: CGFloat) -> Bool {
        settledSlots(items: items, heights: heights, width: width)
            .first { $0.id == draggedID }?
            .frame.contains(center) ?? false
    }

    /// `WidgetLayoutStore.stageMove(_:toIndexOf:)` simulated on a copy.
    static func moved(_ items: [WidgetItem], draggedID: String, toIndexOf targetID: String) -> [WidgetItem] {
        guard let from = items.firstIndex(where: { $0.kind.id == draggedID }),
              let to = items.firstIndex(where: { $0.kind.id == targetID }),
              from != to else { return items }
        var updated = items
        updated.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return updated
    }

    static func movedToEnd(_ items: [WidgetItem], draggedID: String) -> [WidgetItem] {
        guard let from = items.firstIndex(where: { $0.kind.id == draggedID }),
              from != items.count - 1 else { return items }
        var updated = items
        let item = updated.remove(at: from)
        updated.append(item)
        return updated
    }
}

// MARK: - Pure autoscroll policy

/// How fast the popover should scroll while a dragged tile presses into the viewport's
/// top or bottom band. All rects share one y-down coordinate space.
enum WidgetAutoScrollPolicy {
    /// Hot band inside each vertical edge of the visible viewport.
    static let band: CGFloat = 44
    /// pt/s at band entry — slow enough to aim mid-scroll.
    static let minSpeed: CGFloat = 60
    /// pt/s with the tile pressed to the edge.
    static let maxSpeed: CGFloat = 320
    /// Grazing the band boundary by less than this doesn't creep.
    static let deadZone: CGFloat = 3

    /// Scroll velocity in pt/s; negative scrolls toward the top. Zero outside the bands.
    static func velocity(tileRect: CGRect, visible: CGRect) -> CGFloat {
        let topPenetration = (visible.minY + band) - tileRect.minY
        let bottomPenetration = tileRect.maxY - (visible.maxY - band)

        // A tile taller than the viewport can press both bands; follow the deeper one.
        if topPenetration > deadZone, topPenetration >= bottomPenetration {
            return -speed(for: topPenetration)
        }
        if bottomPenetration > deadZone {
            return speed(for: bottomPenetration)
        }
        return 0
    }

    /// Quadratic ramp: gentle at the band edge, fast at the viewport edge.
    private static func speed(for penetration: CGFloat) -> CGFloat {
        let fraction = min(max(penetration / band, 0), 1)
        return minSpeed + (maxSpeed - minSpeed) * fraction * fraction
    }
}

// MARK: - Drag controller

/// The cursor position of an in-flight drag, split into its own object so its 120 Hz
/// updates re-render only the floating tile — never the grid, the tiles, or their
/// frame recorders.
@MainActor
final class WidgetDragPointer: ObservableObject {
    /// Floating-tile center target in grid space. Tracked 1:1 while dragging (never
    /// animated); animated once by the settle spring.
    @Published var location: CGPoint = .zero
}

/// Owns an iOS-Home-Screen-style reorder drag end to end: pickup, cursor and haptic
/// feedback, dwell-based retargeting, edge autoscroll, Escape/right-click cancel, and
/// the velocity-seeded settle. The authoritative session state lives here — never in
/// tile-local view state — because a SwiftUI `DragGesture` can die without `onEnded`
/// (popover close, view re-identification), and every exit path must converge.
@MainActor
final class WidgetDragController: ObservableObject {
    struct Active {
        var kind: WidgetKind
        /// Cursor − tile center at pickup, so the tile stays under the grab point.
        var grabOffset: CGSize
        var size: CGSize
    }

    @Published private(set) var active: Active?
    @Published private(set) var isSettling = false

    /// High-frequency cursor tracking, deliberately outside this object's publisher.
    let pointer = WidgetDragPointer()

    /// Measured tile frames in grid space. Deliberately not `@Published`: they change on
    /// every layout pass, and publishing them would feed rendering back into itself.
    var liveFrames: [WidgetKind: CGRect] = [:]
    /// Content heights captured while no drag is in flight, so hit-testing full-width
    /// tiles never reads a mid-animation frame.
    var settledHeights: [WidgetKind: CGFloat] = [:]
    var gridWidth: CGFloat = 292

    // Context wired by the grid. The stores are app-lifetime singletons, so strong
    // captures in `visibleItems` cannot cycle.
    weak var layout: WidgetLayoutStore?
    var visibleItems: () -> [WidgetItem] = { [] }
    var reduceMotion = false

    // Autoscroll plumbing, resolved by `WidgetScrollViewProbe`.
    weak var scrollView: NSScrollView?
    weak var scrollAnchor: NSView?

    /// `kVK_Escape`, spelled out so this file doesn't need Carbon for one constant.
    private static let escapeKeyCode: UInt16 = 53

    private var driveTimer: Timer?
    private var eventMonitor: Any?
    /// Set while a cancelled gesture is still delivering `onChanged`; cleared on release.
    private var suppressedUntilRelease = false
    private var pendingDecision: WidgetReorderPolicy.Decision = .none
    private var pendingDecisionSince = Date.distantPast
    private var lastDriveTick = Date.distantPast

    var isDragging: Bool { active != nil }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        driveTimer?.invalidate()
    }

    // MARK: Gesture entry points

    func dragChanged(_ kind: WidgetKind, value: DragGesture.Value) {
        guard !suppressedUntilRelease else { return }
        if let current = active {
            if current.kind != kind, !isSettling {
                // A live drag owns the session; ignore stray gestures.
                return
            }
            if isSettling {
                // A settling tile is immediately re-grabbable, and a quick second drag
                // shouldn't be eaten either — the settling drop's order is already
                // committed, so finalize it instantly and start fresh.
                finish()
            }
        }
        if active == nil {
            pickUp(kind, startLocation: value.startLocation, location: value.location)
        }
        guard let active, active.kind == kind, !isSettling else { return }
        pointer.location = value.location
        reassertDragCursor()
        retarget()
    }

    func dragEnded(_ kind: WidgetKind, value: DragGesture.Value) {
        suppressedUntilRelease = false
        guard let active, active.kind == kind, !isSettling else { return }
        settle(cancelled: false, velocity: value.velocity)
    }

    /// Safety net for silent gesture death (`onEnded` is not guaranteed): the tile's
    /// `@GestureState` reset back to idle while this controller still thinks the drag
    /// is live. Deferred one turn so a normally-delivered `onEnded` wins the race.
    func gestureStateDidReset(_ kind: WidgetKind) {
        suppressedUntilRelease = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let active = self.active, active.kind == kind, !self.isSettling else { return }
            self.settle(cancelled: false, velocity: .zero)
        }
    }

    /// Escape or right-click: restore the pre-drag order and spring the tile home.
    func cancelActiveDrag() {
        guard active != nil, !isSettling else { return }
        suppressedUntilRelease = true
        WidgetDragFeedback.cancel()
        settle(cancelled: true, velocity: .zero)
    }

    /// A drag can end without any gesture callback (popover closed, tile hidden from
    /// another window, edit mode toggled off). Commit whatever order the drag reached
    /// and drop the floating tile in place — Escape is the only revert path.
    func finalizeIfNeeded() {
        guard isDragging || isSettling else { return }
        layout?.persistNow()
        NSCursor.arrow.set()
        finish()
    }

    // MARK: Session lifecycle

    private func pickUp(_ kind: WidgetKind, startLocation: CGPoint, location: CGPoint) {
        // Pick up from the settled slot, not the live frame — grabbing a tile
        // mid-reflow would otherwise bake an animation offset into the drag.
        guard let frame = settledSlot(for: kind)?.frame ?? liveFrames[kind] else { return }
        pointer.location = location
        active = Active(
            kind: kind,
            grabOffset: CGSize(width: startLocation.x - frame.midX,
                               height: startLocation.y - frame.midY),
            size: frame.size
        )
        pendingDecision = .none
        WidgetDragFeedback.pickup()
        NSCursor.closedHand.set()
        installEventMonitor()
        startDrive()
    }

    /// Commits or reverts the order immediately (the drop is the user's decision —
    /// never leave it hostage to an animation), then springs the floating tile into
    /// the hole with the release velocity carried through.
    private func settle(cancelled: Bool, velocity: CGSize) {
        guard let active, !isSettling else { return }
        stopDrive()
        removeEventMonitor()
        NSCursor.arrow.set()

        if cancelled {
            layout?.revertStagedChanges()
        } else {
            layout?.persistNow()
        }

        let destination = settledSlot(for: active.kind)?.frame
            ?? liveFrames[active.kind]
            ?? .zero
        let restingPoint = CGPoint(x: destination.midX + active.grabOffset.width,
                                   y: destination.midY + active.grabOffset.height)
        guard let animation = settleAnimation(from: pointer.location, to: restingPoint,
                                              velocity: velocity) else {
            finish()
            return
        }
        withAnimation(animation) {
            isSettling = true
            pointer.location = restingPoint
        } completion: { [weak self] in
            guard let self else { return }
            // A new pickup may have finalized this drop early; don't clobber its state.
            guard self.isSettling, self.active?.kind == active.kind else { return }
            self.finish()
        }
    }

    private func finish() {
        active = nil
        isSettling = false
        pendingDecision = .none
        stopDrive()
        removeEventMonitor()
    }

    // MARK: Retargeting

    /// Runs on every gesture change and every drive tick, so retargeting (and its
    /// dwell clock) keeps working while the cursor holds still during an autoscroll.
    private func retarget() {
        guard let active, let layout, !isSettling else { return }
        let center = CGPoint(x: pointer.location.x - active.grabOffset.width,
                             y: pointer.location.y - active.grabOffset.height)
        let items = visibleItems()
        let decision = WidgetReorderPolicy.decision(center: center,
                                                    draggedID: active.kind.id,
                                                    items: items,
                                                    heights: heights(for: items),
                                                    width: gridWidth)
        guard decision != .none else {
            pendingDecision = .none
            return
        }
        if decision != pendingDecision {
            pendingDecision = decision
            pendingDecisionSince = Date()
            return
        }
        guard Date().timeIntervalSince(pendingDecisionSince) >= WidgetReorderPolicy.dwell else { return }
        pendingDecision = .none

        withAnimation(GeraldineMotion.animation(.gentleSpring, reduceMotion: reduceMotion)) {
            switch decision {
            case .move(let targetID):
                guard let target = WidgetKind(id: targetID) else { return }
                layout.stageMove(active.kind, toIndexOf: target)
            case .moveToEnd:
                layout.stageMoveToEnd(active.kind)
            case .none:
                break
            }
        }
        WidgetDragFeedback.aligned()
    }

    private func heights(for items: [WidgetItem]) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        for item in items {
            if let height = settledHeights[item.kind] { result[item.kind.id] = height }
        }
        return result
    }

    private func settledSlot(for kind: WidgetKind) -> WidgetGridMetrics.Slot? {
        let items = visibleItems()
        return WidgetReorderPolicy.settledSlots(items: items,
                                                heights: heights(for: items),
                                                width: gridWidth)
            .first { $0.id == kind.id }
    }

    // MARK: Drive timer (autoscroll + dwell)

    private func startDrive() {
        stopDrive()
        lastDriveTick = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // Timers scheduled in .common mode fire on the main run loop even while
            // an event-tracking drag is in progress.
            MainActor.assumeIsolated { self?.driveTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        driveTimer = timer
    }

    private func stopDrive() {
        driveTimer?.invalidate()
        driveTimer = nil
    }

    private func driveTick() {
        guard active != nil, !isSettling else { return }
        let now = Date()
        let dt = min(now.timeIntervalSince(lastDriveTick), 1.0 / 20.0)
        lastDriveTick = now
        autoscrollIfNeeded(dt: dt)
        retarget()
        reassertDragCursor()
    }

    private func autoscrollIfNeeded(dt: TimeInterval) {
        guard let active,
              let scrollView,
              let anchor = scrollAnchor,
              let documentView = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollRange = documentHeight - visible.height
        guard scrollRange > 1 else { return }

        let center = CGPoint(x: pointer.location.x - active.grabOffset.width,
                             y: pointer.location.y - active.grabOffset.height)
        let tileInGrid = CGRect(x: center.x - active.size.width / 2,
                                y: center.y - active.size.height / 2,
                                width: active.size.width,
                                height: active.size.height)
        // The probe shares the grid's frame and is flipped like SwiftUI's own space,
        // so AppKit's rect conversion lands the tile in document coordinates whether
        // or not the hosted document view is itself flipped.
        let tileInDocument = anchor.convert(tileInGrid, to: documentView)

        // The policy — and the grid space the pointer lives in — are y-down. An
        // unflipped document view measures upward, so mirror into y-down, decide
        // there, then map the result back.
        let flipped = documentView.isFlipped
        func toDown(_ y: CGFloat, height: CGFloat) -> CGFloat {
            flipped ? y : documentHeight - y - height
        }
        let tileDown = CGRect(x: tileInDocument.minX,
                              y: toDown(tileInDocument.minY, height: tileInDocument.height),
                              width: tileInDocument.width,
                              height: tileInDocument.height)
        let visibleDownOriginY = toDown(visible.origin.y, height: visible.height)
        let visibleDown = CGRect(x: visible.origin.x, y: visibleDownOriginY,
                                 width: visible.width, height: visible.height)

        let velocity = WidgetAutoScrollPolicy.velocity(tileRect: tileDown, visible: visibleDown)
        guard velocity != 0 else { return }

        let targetDownY = min(max(visibleDownOriginY + velocity * dt, 0), scrollRange)
        let appliedDelta = targetDownY - visibleDownOriginY
        guard abs(appliedDelta) > 0.01 else { return }

        let targetNativeY = flipped ? targetDownY : documentHeight - targetDownY - visible.height
        clip.setBoundsOrigin(NSPoint(x: visible.origin.x, y: targetNativeY))
        scrollView.reflectScrolledClipView(clip)
        // The cursor is stationary in window space while the grid slides under it, so
        // its grid-space position — and the floating tile with it — must follow.
        pointer.location.y += appliedDelta
    }

    // MARK: Feedback plumbing

    /// Hover effects and view updates keep resetting the AppKit cursor, so the closed
    /// hand is re-asserted on every gesture change and drive tick.
    private func reassertDragCursor() {
        guard isDragging, !isSettling else { return }
        if NSCursor.current != NSCursor.closedHand {
            NSCursor.closedHand.set()
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            // Escape is swallowed so the popover's own Escape handling can't dismiss the
            // panel mid-gesture; right-click during a drag is the classic macOS cancel.
            // Only these two facts cross into the actor — NSEvent itself is not Sendable.
            let cancels = event.type == .rightMouseDown
                || (event.type == .keyDown && event.keyCode == Self.escapeKeyCode)
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self, cancels, self.isDragging, !self.isSettling else { return false }
                self.cancelActiveDrag()
                return true
            }
            return swallowed ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: Settle spring

    /// The gentle reflow spring, seeded with the release velocity projected onto the
    /// path home so a flicked tile keeps its momentum into the hole.
    private func settleAnimation(from: CGPoint, to: CGPoint, velocity: CGSize) -> Animation? {
        guard !reduceMotion else { return nil }
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let speed = (velocity.width * velocity.width + velocity.height * velocity.height).squareRoot()
        guard distance > 0.5, speed > 40 else {
            return GeraldineMotion.animation(.gentleSpring, reduceMotion: false)
        }
        let along = (velocity.width * dx + velocity.height * dy) / distance
        // interpolatingSpring's initialVelocity is normalized against the travel
        // distance; clamp so a hard flick can't hurl the tile through its slot.
        let initialVelocity = min(max(along / distance, -4), 12)
        // response ≈ 0.35 s, damping ratio ≈ 0.78 — springy for the hero tile, while
        // the displaced neighbors keep the overshoot-free gentleSpring.
        return .interpolatingSpring(mass: 1, stiffness: 320, damping: 28,
                                    initialVelocity: initialVelocity)
    }
}

// MARK: - Haptics

/// Trackpad feedback for the drag's key moments. Force Touch trackpads only — silent
/// on other hardware, so it is never the sole feedback channel.
enum WidgetDragFeedback {
    static func pickup() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// One tick per committed reorder, mirroring Apple's documented use of
    /// `.alignment` for drag snapping. Never per pointer-move or autoscroll frame.
    static func aligned() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func cancel() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - Scroll view probe

/// Resolves the popover's enclosing `NSScrollView` (and a stable anchor for grid →
/// document coordinate conversion) from inside SwiftUI content. Zero layout footprint.
struct WidgetScrollViewProbe: NSViewRepresentable {
    let controller: WidgetDragController

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = resolver()
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onResolve = resolver()
        nsView.resolve()
    }

    private func resolver() -> (NSScrollView?, NSView) -> Void {
        { [weak controller] scrollView, anchor in
            controller?.scrollView = scrollView
            controller?.scrollAnchor = anchor
        }
    }

    final class ProbeView: NSView {
        var onResolve: ((NSScrollView?, NSView) -> Void)?

        // Match SwiftUI's y-down space so grid coordinates convert 1:1.
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func resolve() {
            onResolve?(enclosingScrollView, self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Grab cursor

/// Open-hand cursor over a grabbable tile in edit mode; suspended while a drag is in
/// flight (the controller owns the closed hand then). Push/pop balanced on every exit.
struct GrabHandCursor: ViewModifier {
    let active: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard active else { return releaseCursor() }
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onChange(of: active) { _, isActive in
                if !isActive { releaseCursor() }
            }
            .onDisappear { releaseCursor() }
    }

    /// Balances the `push()` from hover, on every path that ends the hover.
    private func releaseCursor() {
        guard hovering else { return }
        NSCursor.pop()
        hovering = false
    }
}

extension View {
    /// Cue that the tile can be grabbed: an open hand on hover while `active`.
    func grabHandCursor(active: Bool) -> some View {
        modifier(GrabHandCursor(active: active))
    }
}
