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
/// 队列满时丢弃最旧的待消费帧，让队列始终保留最近捕获的画面，
/// 避免消费端积压耗尽后帧间隔跳变导致快速滚动帧失配。
public struct RollingFrameBuffer<Element> {
    public let capacity: Int
    private var elements: [Element] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { elements.count }

    public mutating func append(_ element: Element) {
        if elements.count < capacity {
            elements.append(element)
        } else {
            // 队列满：丢弃最旧的待消费帧，保持消费帧间隔均匀，
            // 并让队列始终贴近当前画面。
            elements.removeFirst()
            elements.append(element)
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
