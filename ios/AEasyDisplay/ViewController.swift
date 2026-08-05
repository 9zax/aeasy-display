// One screen: video in the safe area, a status label until frames flow, touch
// forwarded as the 5-byte packets the Mac already speaks, and the safe-area size
// reported as type-3 — which is also the rotation signal.

import UIKit
import AVFoundation

final class ViewController: UIViewController {
    private let listener = StreamListener()
    private let scanner = NalScanner()
    private let decoder = Decoder()
    private let videoView = UIView()
    private let status = UILabel()

    // MARK: chrome

    // Android's SYSTEM_UI_FLAG_FULLSCREEN: without this, iPhone 7's safe area excludes
    // a 20 pt status bar, and every in-call double-height bar change would trigger a
    // spurious resize -> server restart
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // defers only the FIRST edge swipe — the second always reaches the system.
    // Second line of defence; the real one is that video, touch and virtual display
    // are all the safe-area rect, so the home-indicator zone is outside the video.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()

        videoView.translatesAutoresizingMaskIntoConstraints = false
        // isMultipleTouchEnabled stays false (the default): the second finger is never
        // delivered, which IS the Android single-finger limitation — and cleaner than
        // Android, where lifting finger A teleports the cursor to finger B
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        videoView.layer.addSublayer(decoder.layer)

        status.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .lightGray
        status.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        status.numberOfLines = 0
        status.textAlignment = .center
        // only visible while disconnected, so the tap can't collide with stream touches
        status.isUserInteractionEnabled = true
        status.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openSettings)))
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        showWaiting()

        decoder.onError = { [weak self] msg in DispatchQueue.main.async { self?.show(msg) } }

        listener.onData = { [weak self] chunk in
            guard let self else { return }
            let nals = self.scanner.feed(chunk)
            guard !nals.isEmpty else { return }
            DispatchQueue.main.async {
                if !self.status.isHidden { self.status.isHidden = true }
                nals.forEach(self.decoder.consume)
            }
        }
        listener.onState = { [weak self] connected in
            guard let self else { return }
            if connected {
                self.scanner.reset()
                self.decoder.reset()
                self.lastSent = nil          // new server process: re-report the size
                self.reportSizeSoon()
            } else {
                self.showWaiting()
            }
        }

        let nc = NotificationCenter.default
        // didBecomeActive, not willEnterForeground — the corrective layout pass runs
        // in between, and reporting from the earlier hook would send a stale size
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reportSizeSoon()
        }
        // TN2277: rebuild the listener across background, or the socket may be dead
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.listener.stop()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.listener.start()
        }

        listener.start()
        StreamListener.triggerLocalNetworkPrompt()
    }

    private func showWaiting() {
        let ip = StreamListener.wifiAddress().map { "\nWi-Fi: aeasy wifi \($0)" } ?? ""
        show("Waiting for Mac…\nUSB: plug in and run `aeasy start`\(ip)\n\nNot connecting? Tap here → allow Local Network")
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    private func show(_ text: String) { status.text = text; status.isHidden = false }

    // MARK: size reporting (type-3) — one function, one hook

    private var lastSent: (Int, Int)?
    private var debounce: DispatchWorkItem?

    // viewDidLayoutSubviews is the ONLY place bounds and safeAreaInsets are both
    // correct — viewWillTransition still has the pre-rotation safe area. One hook
    // covers rotation, Split View, Slide Over and status-bar changes alike.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        decoder.layer.frame = videoView.bounds
        reportSizeSoon()
    }

    private func reportSizeSoon() {
        // background gate = the whole foreground-focus check: iOS lays out a
        // backgrounded app for its App Switcher snapshot, and that must not flip
        // the Mac display. willResignActive is deliberately NOT used — Control
        // Center and friends fire it with no backgrounding and no resize.
        guard UIApplication.shared.applicationState != .background else { return }
        let size = view.safeAreaLayoutGuide.layoutFrame.size
        guard size.width > 0 else { return }
        let scale = view.window?.windowScene?.screen.nativeScale ?? UIScreen.main.nativeScale
        let reported = Protocol.reportedSize(points: (size.width, size.height), nativeScale: scale)
        guard reported != lastSent ?? (-1, -1) else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastSent = reported
            var pkt = Data([3])
            pkt.append(contentsOf: withUnsafeBytes(of: UInt16(reported.0).bigEndian, Array.init))
            pkt.append(contentsOf: withUnsafeBytes(of: UInt16(reported.1).bigEndian, Array.init))
            self.listener.send(pkt)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: touch — raw handlers, no gesture recognizer (recognizers can cancel
    // touches already reported). Coordinates normalise over the video view, which
    // IS the safe-area rect, so no un-letterboxing — the Android invariant.

    private var active: UITouch?

    private func sendTouch(_ type: UInt8, _ t: UITouch) {
        let p = t.location(in: videoView)
        let b = videoView.bounds
        guard b.width > 0, b.height > 0 else { return }
        // clamp BEFORE the integer conversion: a drag leaving the view goes negative,
        // and UInt16(negativeDouble) traps in Swift where Kotlin merely truncates
        let nx = min(1, max(0, p.x / b.width)), ny = min(1, max(0, p.y / b.height))
        var pkt = Data([type])
        pkt.append(contentsOf: withUnsafeBytes(of: UInt16(nx * 65535).bigEndian, Array.init))
        pkt.append(contentsOf: withUnsafeBytes(of: UInt16(ny * 65535).bigEndian, Array.init))
        listener.send(pkt)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard active == nil, let t = touches.first else { return }
        active = t
        sendTouch(0, t)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // never touches.first — Set ordering is undefined; track the active touch
        guard let t = active, touches.contains(t) else { return }
        sendTouch(1, t)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = active, touches.contains(t) else { return }
        active = nil
        sendTouch(2, t)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // cancel maps to UP, or the Mac button sticks down — same as Android
        guard let t = active, touches.contains(t) else { return }
        active = nil
        sendTouch(2, t)
    }
}
