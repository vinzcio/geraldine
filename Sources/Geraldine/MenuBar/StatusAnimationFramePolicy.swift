import Foundation

/// Caps status-item compositing at 30 fps while still guaranteeing the final
/// frame. The status item sits on a 60–144 Hz display link; a 0.24 s roll does
/// not need a fresh `NSImage` at every vblank, and each frame forces
/// WindowServer to recomposite the menu bar.
struct StatusAnimationFramePolicy {
    static let framesPerSecond: Double = 30
    static let minimumInterval: TimeInterval = 1 / framesPerSecond

    private var lastRenderedAt: TimeInterval?

    mutating func reset() {
        lastRenderedAt = nil
    }

    /// `isFinal` always renders so an animation can never stall one frame short.
    mutating func shouldRender(at now: TimeInterval, isFinal: Bool) -> Bool {
        guard now.isFinite else { return true }
        if isFinal {
            lastRenderedAt = now
            return true
        }
        if let lastRenderedAt, now >= lastRenderedAt,
           now - lastRenderedAt < Self.minimumInterval {
            return false
        }
        lastRenderedAt = now
        return true
    }
}

/// Everything that changes the pixels of the status item. Monitor publishes
/// arrive several times per second (CPU, memory, network, GPU, thermal); when
/// only a hidden metric moved, the existing image is already correct and the
/// redraw can be skipped.
struct StatusRenderSignature: Equatable {
    struct Sample: Equatable {
        var timestamp: TimeInterval
        var value: Double
    }

    var kind: String
    var sourceID: UInt64?
    var label: String
    var widthSample: String
    var glyph: String?
    var colorToken: String
    var samples: [Sample]
    var domainLower: Double?
    var domainUpper: Double?
    var showsLatestEndpoint: Bool

    init(
        kind: String,
        sourceID: UInt64? = nil,
        label: String,
        widthSample: String,
        glyph: String? = nil,
        colorToken: String,
        samples: [Sample] = [],
        domain: ClosedRange<Double>? = nil,
        showsLatestEndpoint: Bool = true
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.label = label
        self.widthSample = widthSample
        self.glyph = glyph
        self.colorToken = colorToken
        self.samples = samples
        self.domainLower = domain?.lowerBound
        self.domainUpper = domain?.upperBound
        self.showsLatestEndpoint = showsLatestEndpoint
    }
}
