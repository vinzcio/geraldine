import Foundation

/// Everything that changes the pixels of the status item. Monitor publishes
/// arrive several times per second (CPU, memory, network, GPU, thermal); when
/// only a hidden metric moved, the existing image is already correct and the
/// redraw can be skipped.
struct StatusRenderSignature: Equatable {
    struct Sample: Equatable {
        var timestamp: TimeInterval
        var value: Double
        var sessionID: UUID? = nil
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
    var timelineEnd: TimeInterval?

    init(
        kind: String,
        sourceID: UInt64? = nil,
        label: String,
        widthSample: String,
        glyph: String? = nil,
        colorToken: String,
        samples: [Sample] = [],
        domain: ClosedRange<Double>? = nil,
        showsLatestEndpoint: Bool = true,
        timelineEnd: TimeInterval? = nil
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
        self.timelineEnd = timelineEnd
    }
}

/// A signature is reusable only after its final image reaches the current
/// status button. Replacing the button or interrupting a render invalidates it.
struct StatusRenderCache {
    private var renderedSignature: StatusRenderSignature?

    func canReuse(_ signature: StatusRenderSignature, hasImage: Bool) -> Bool {
        hasImage && renderedSignature == signature
    }

    mutating func record(_ signature: StatusRenderSignature) {
        renderedSignature = signature
    }

    mutating func invalidate() {
        renderedSignature = nil
    }
}
