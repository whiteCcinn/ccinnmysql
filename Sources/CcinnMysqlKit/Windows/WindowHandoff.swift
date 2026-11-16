import Foundation

/// Hands the connection to open (profile, password in use, …) to a window this process opens. A `WindowRequest`
/// only carries ids, because SwiftUI may persist and restore it, so the payload stays here, in memory, until the
/// new window takes it, exactly once.
///
/// A request without a payload was not created by this process: it is a window macOS restored after a relaunch.
/// It takes exactly the path of a window opened without a request (connection screen, launch arguments) and never
/// connects from the request itself.
@MainActor
public final class WindowHandoff<Payload> {
    private var pending: [UUID: Payload] = [:]

    public init() {}

    /// Keeps `payload` for the window that `openWindow(value:)` will create with the returned request.
    public func request(profileID: UUID, payload: Payload) -> WindowRequest {
        let request = WindowRequest(profileID: profileID)
        pending[request.nonce] = payload
        return request
    }

    /// The payload handed to `request`, removed so that no other window can take it. Nil both for a window opened
    /// without a request and for a request this process did not create, so the two cannot diverge.
    public func take(_ request: WindowRequest?) -> Payload? {
        guard let request else { return nil }
        return pending.removeValue(forKey: request.nonce)
    }

    /// Payloads not taken yet.
    public var pendingCount: Int { pending.count }
}
