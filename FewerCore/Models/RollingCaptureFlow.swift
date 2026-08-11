public enum RollingCapturePhase: Equatable, Sendable {
    case idle
    case preparing
    case capturing
    case paused
    case finishing
    case completed
    case cancelled
}

public enum RollingCaptureEvent: Sendable {
    case start
    case firstFrameCaptured
    case pause
    case resume
    case retryPreparation
    case beginFinishing
    case complete
    case cancel
}

public enum RollingCaptureTransitions {
    public static func next(
        from phase: RollingCapturePhase,
        event: RollingCaptureEvent
    ) -> RollingCapturePhase? {
        switch (phase, event) {
        case (.idle, .start): .preparing
        case (.preparing, .firstFrameCaptured): .capturing
        case (.preparing, .pause), (.capturing, .pause), (.finishing, .pause): .paused
        case (.paused, .resume): .capturing
        case (.paused, .retryPreparation): .preparing
        case (.capturing, .beginFinishing), (.paused, .beginFinishing): .finishing
        case (.finishing, .complete): .completed
        case (.preparing, .cancel), (.capturing, .cancel), (.paused, .cancel), (.finishing, .cancel): .cancelled
        default: nil
        }
    }
}

/// 连续滚动截图的有界桥接帧队列。消费端必须按捕获顺序读取，
/// 仅在生产速度超过容量时丢弃最旧帧，避免直接跳到最新画面而失去重叠区。
public struct RollingFrameBuffer<Element> {
    public let capacity: Int
    private var elements: [Element] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { elements.count }

    public mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }

    public mutating func removeNext() -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements.removeFirst()
    }

    public mutating func removeAll() {
        elements.removeAll(keepingCapacity: false)
    }
}
