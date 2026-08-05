// The device-side listener: usbmuxd terminates its tunnel on the device's own
// loopback, so a plain NWListener on :7355 serves both USB (iproxy relay) and Wi-Fi
// (socat against our LAN IP). No entitlement needed — verified against shipping
// precedent (PeerTalk/Duet, OpenDisplay).

import Foundation
import Network

final class StreamListener {
    private var listener: NWListener?
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "net")

    var onData: ((Data) -> Void)?          // video bytes, already on the net queue
    var onState: ((Bool) -> Void)?         // connected / disconnected, main queue

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            // TN2277: iOS can reclaim a suspended app's listening socket, so we tear
            // down on background and rebuild on foreground — reuse survives TIME_WAIT
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params, on: 7355) else {
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart() }
                return
            }
            l.newConnectionLimit = 1       // one fullscreen pane in phase 1, by construction
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        }
    }

    func stop() {
        queue.async { [self] in
            conn?.cancel(); conn = nil
            listener?.cancel(); listener = nil
        }
    }

    private func restart() { stop(); start() }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                DispatchQueue.main.async { self?.onState?(true) }
                self?.recv(c)
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.onState?(false) }
                self?.queue.async { if self?.conn === c { self?.conn = nil } }
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func recv(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            if complete || err != nil { c.cancel(); return }
            self.recv(c)
        }
    }

    /// Upstream 5-byte packets (touch + type-3). Fire-and-forget, as on Android.
    func send(_ d: Data) {
        queue.async { [self] in
            conn?.send(content: d, completion: .contentProcessed { _ in })
        }
    }

    /// The device's Wi-Fi IP (en0), for the on-screen label — Wi-Fi mode is
    /// `aeasy wifi <this>` on the Mac; there is no discovery protocol on purpose.
    static func wifiAddress() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
