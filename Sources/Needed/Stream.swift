import Foundation
import Network

/// WS /v1/stream: incoming events, reconnecting with backoff.
@MainActor
final class Stream {
    var onSignal: () -> Void = {}
    /// Take signals to anyone too; set before `start` or followed by `restart`.
    var anyone = true
    var onAuthLost: () -> Void = {}
    /// The address book may have changed: on every (re)connect, since events
    /// could be missed while offline, and on a "sync" hint from the server.
    var onSync: () -> Void = {}
    /// True once the server said "ready" on the current socket, false when it is gone.
    var onOnline: (Bool) -> Void = { _ in }

    private let auth: Auth
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    /// Pings sent on the current socket and the last one answered.
    private var pingsSent = 0
    private var pongsSeen = 0
    private let path = NWPathMonitor()
    /// The interface in use ("en0", nil when offline), once known.
    private var network: String?
    private var networkKnown = false
    /// Bumped on every (re)connect; callbacks of an older socket are ignored.
    private var generation = 0
    private var backoff: Double = 1
    private var running = false
    /// The server turned the last handshake down: the cached token is stale.
    private var refreshToken = false
    private var online = false {
        didSet { if online != oldValue { onOnline(online) } }
    }

    init(auth: Auth) {
        self.auth = auth
        path.pathUpdateHandler = { [weak self] p in
            let now = p.status == .satisfied ? p.availableInterfaces.first?.name ?? "?" : nil
            Task { @MainActor in self?.networkChanged(to: now) }
        }
        path.start(queue: .main)
    }

    func start() {
        guard !running else { return }
        running = true
        backoff = 1
        connect()
    }

    func stop() {
        running = false
        teardown()
    }

    /// After sleep or a network change the old socket is likely dead.
    func restart() {
        guard running else { return }
        teardown()
        backoff = 1
        connect()
    }

    private func teardown() {
        generation += 1
        online = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        generation += 1
        let gen = generation
        Task { @MainActor in
            let token: String
            do {
                token = try await auth.token(forceRefresh: refreshToken)
                refreshToken = false
            } catch let error as AuthError where error.endsSession {
                onAuthLost()
                return
            } catch {
                scheduleReconnect(gen)
                return
            }
            guard running, gen == generation else { return }
            var url = URLComponents(url: Config.apiBase.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
            url.scheme = "wss"
            if !anyone {
                url.queryItems = [URLQueryItem(name: "anyone", value: "false")]
            }
            var req = URLRequest(url: url.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(Config.client, forHTTPHeaderField: "X-Client")
            let socket = URLSession.shared.webSocketTask(with: req)
            task = socket
            socket.resume()
            receive(socket, gen)
            pingsSent = 0
            pongsSeen = 0
            pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.ping(socket, gen) }
            }
        }
    }

    /// A socket can die without an error (Wi-Fi gone, a router dropped it):
    /// TCP would notice only minutes later, so no pong in 10 s means reconnect.
    private func ping(_ socket: URLSessionWebSocketTask, _ gen: Int) {
        guard gen == generation else { return }
        pingsSent += 1
        let n = pingsSent
        socket.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if error != nil {
                    self.scheduleReconnect(gen)
                } else {
                    self.pongsSeen = max(self.pongsSeen, n)
                }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, gen == self.generation, self.pongsSeen < n else { return }
            self.scheduleReconnect(gen)
        }
    }

    /// Back online or on another network: the old socket is likely dead.
    private func networkChanged(to now: String?) {
        let changed = networkKnown && now != network
        network = now
        networkKnown = true
        if changed, now != nil {
            restart()
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask, _ gen: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure:
                    if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                        self.refreshToken = true
                    }
                    self.scheduleReconnect(gen)
                case .success(let message):
                    if case .string(let text) = message {
                        self.handle(text)
                    }
                    self.receive(socket, gen)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        switch msg["type"] as? String {
        case "ready":
            backoff = 1
            online = true
            onSync()
        case "sync":
            onSync()
        case "event":
            // Unknown types and versions are ignored, so old apps survive new events.
            guard let event = msg["event"] as? [String: Any],
                  event["type"] as? String == "signal",
                  event["v"] as? Int == 1 else { return }
            onSignal()
        default:
            break
        }
    }

    private func scheduleReconnect(_ gen: Int) {
        guard running, gen == generation else { return }
        teardown()
        let next = generation
        let delay = backoff
        backoff = min(backoff * 2, 60)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.running, self.generation == next else { return }
            self.connect()
        }
    }
}
