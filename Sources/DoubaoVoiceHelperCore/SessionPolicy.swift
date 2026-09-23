import Foundation

public enum SessionRole: Equatable, Sendable {
    case toggle
    case hold
}

public enum SessionPhase: Equatable, Sendable {
    case listening
    case processing
}

public enum SessionTriggerKind: Equatable, Sendable {
    case down
    case up
}

public struct ActiveSessionState: Equatable, Sendable {
    public var role: SessionRole
    public var phase: SessionPhase
    /// Seconds since the session started listening.
    public var elapsed: TimeInterval

    public init(role: SessionRole, phase: SessionPhase, elapsed: TimeInterval) {
        self.role = role
        self.phase = phase
        self.elapsed = elapsed
    }
}

public enum SessionTriggerAction: Equatable, Sendable {
    public enum IgnoreReason: String, Sendable {
        case paused
        case onboarding
        case cooldown
        case debounce
        case busy
        case noSession
    }

    case start
    case stop
    /// Cancel the existing session (without telling Doubao to abort) and
    /// start a new one immediately.
    case restart
    /// Abort the existing session in Doubao, then start a new one.
    case preemptAndStart
    case ignore(IgnoreReason)
}

public struct SessionTriggerContext: Equatable, Sendable {
    public var paused: Bool
    public var onboardingCompleted: Bool
    public var inCooldown: Bool

    public init(paused: Bool, onboardingCompleted: Bool, inCooldown: Bool) {
        self.paused = paused
        self.onboardingCompleted = onboardingCompleted
        self.inCooldown = inCooldown
    }
}

/// Decides how a mouse trigger affects the single dictation session.
public enum SessionTriggerPolicy {
    public static let toggleDebounce: TimeInterval = 0.15
    public static let holdCooldown: TimeInterval = 0.35
    public static let toggleTimeout: TimeInterval = 60

    public static func decide(
        role: SessionRole,
        kind: SessionTriggerKind,
        active: ActiveSessionState?,
        context: SessionTriggerContext
    ) -> SessionTriggerAction {
        switch (role, kind) {
        case (.hold, .up):
            guard let active, active.role == .hold, active.phase == .listening else {
                return .ignore(.noSession)
            }
            return .stop

        case (.toggle, .up):
            return .ignore(.noSession)

        case (.hold, .down):
            if let blocked = startBlocker(context, checkCooldown: true) {
                return .ignore(blocked)
            }
            guard let active else { return .start }
            return active.role == .toggle ? .preemptAndStart : .ignore(.busy)

        case (.toggle, .down):
            guard let active else {
                if let blocked = startBlocker(context, checkCooldown: true) {
                    return .ignore(blocked)
                }
                return .start
            }
            if active.phase == .processing {
                // A new toggle press means the user wants to talk again; the
                // pending macro pass of the previous utterance is dropped.
                if let blocked = startBlocker(context, checkCooldown: false) {
                    return .ignore(blocked)
                }
                return .restart
            }
            guard active.role == .toggle else {
                return .ignore(.busy)
            }
            return active.elapsed < toggleDebounce ? .ignore(.debounce) : .stop
        }
    }

    private static func startBlocker(
        _ context: SessionTriggerContext,
        checkCooldown: Bool
    ) -> SessionTriggerAction.IgnoreReason? {
        if context.paused { return .paused }
        if !context.onboardingCompleted { return .onboarding }
        if checkCooldown, context.inCooldown { return .cooldown }
        return nil
    }
}

/// Timing for waiting on Doubao's final text after dictation stops.
public enum SettlePolicy {
    /// Doubao streams partial results and revises punctuation after stopping;
    /// the value must stay unchanged this long before it is treated as final.
    public static let quietPeriod: TimeInterval = 0.3
    public static let minimumTimeout: TimeInterval = 1.5
    public static let maximumTimeout: TimeInterval = 4.0
    public static let timeoutPerListeningSecond: TimeInterval = 0.1
    /// Extra time the processing watchdog allows beyond the settle timeout
    /// for AX write-back and verification.
    public static let watchdogMargin: TimeInterval = 2.0

    public static func timeout(forListeningDuration duration: TimeInterval) -> TimeInterval {
        let scaled = minimumTimeout + max(duration, 0) * timeoutPerListeningSecond
        return min(scaled, maximumTimeout)
    }

    public static func watchdog(forListeningDuration duration: TimeInterval) -> TimeInterval {
        timeout(forListeningDuration: duration) + watchdogMargin
    }
}
