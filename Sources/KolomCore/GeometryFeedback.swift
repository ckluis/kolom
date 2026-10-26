import CoreGraphics

/// App-generated AX notifications are observations, not layout instructions.
/// A successful write can settle asynchronously or be constrained by the app.
public struct GeometryFeedback {
    public enum Decision: Equatable { case unchanged, settling, userChange, retry, constrained }
    private struct Request {
        var frame: CGRect
        var time: Double
        var attempts: Int
    }
    private var requests: [String: Request] = [:]
    public init() {}
    public mutating func recordWrite(_ id: String, frame: CGRect, time: Double) {
        let old = requests[id]
        requests[id] = Request(frame: frame, time: time, attempts: old?.frame == frame ? old!.attempts + 1 : 1)
    }
    public func decision(_ id: String, actual: CGRect, time: Double, userGesture: Bool) -> Decision {
        guard let request = requests[id] else { return .unchanged }
        let target = request.frame
        let differs =
            abs(actual.minX - target.minX) > 4 || abs(actual.minY - target.minY) > 4
            || abs(actual.width - target.width) > 4 || abs(actual.height - target.height) > 4
        guard differs else { return .unchanged }
        if userGesture { return .userChange }
        guard time - request.time >= 0.6 else { return .settling }
        return request.attempts < 2 ? .retry : .constrained
    }
    public mutating func retain(_ ids: Set<String>) { requests = requests.filter { ids.contains($0.key) } }
}
