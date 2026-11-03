import Foundation

public protocol KeepAwakeHold: Sendable {
    func release()
}

public protocol KeepAwake: Sendable {
    func hold(reason: String) -> any KeepAwakeHold
}

public struct ProcessKeepAwake: KeepAwake {
    public init() {}

    public func hold(reason: String) -> any KeepAwakeHold {
        ProcessActivity(token: ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason))
    }
}

private final class ProcessActivity: KeepAwakeHold, @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(token: any NSObjectProtocol) {
        self.token = token
    }

    func release() {
        ProcessInfo.processInfo.endActivity(token)
    }
}
