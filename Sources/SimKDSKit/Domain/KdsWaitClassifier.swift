import Foundation

public enum KdsWaitSeverity: String, Sendable, Hashable {
    case normal, warning, critical
}

public enum KdsWaitClassifier {
    public static let warningThreshold = Duration.seconds(5 * 60)
    public static let criticalThreshold = Duration.seconds(10 * 60)

    public static func classify(_ waitDuration: Duration) -> KdsWaitSeverity {
        switch waitDuration {
        case criticalThreshold...: .critical
        case warningThreshold...: .warning
        default: .normal
        }
    }
}
