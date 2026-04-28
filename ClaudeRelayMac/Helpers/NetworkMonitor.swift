import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true

    static let connectivityRestored = Notification.Name("com.clauderelay.mac.connectivityRestored")

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.clauderelay.mac.networkMonitor")
    private var wasDisconnected = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let priorDisconnected = self.wasDisconnected
                self.isConnected = connected
                if !connected {
                    self.wasDisconnected = true
                } else if priorDisconnected {
                    self.wasDisconnected = false
                    NotificationCenter.default.post(name: Self.connectivityRestored, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
