// EventLog.swift — append-only event log client (iOS / watchOS, Foundation only)
//
// Every user action, request, fetch, retry, error and job step the app performs
// is written to the project's Supabase `public.event_log` table through the
// `log_events` RPC. The table is append-only at the database level (UPDATE,
// DELETE and TRUNCATE are blocked by trigger), so nothing the app records can
// later be edited or removed.
//
// Wire-up (one line in the @main App init):
//     EventLog.configure(url: "https://<ref>.supabase.co", apiKey: "<anon key>", project: "<app>")
//
// Then anywhere:
//     EventLog.action("tap.start_recording", ["screen": "home"])
//     EventLog.error(err, name: "upload.failed")
//     let job = EventLog.job("sync"); job.step("fetch"); job.end()
//     let (data, resp) = try await EventLog.shared.data(for: request, retries: 2)   // logged fetch + retries
//     Button("Go") { ... }.logTap("tap.go")                                           // SwiftUI helper
//
// Events are batched, flushed every few seconds and when the app backgrounds,
// and spilled to disk when offline so nothing is lost between launches.
// Nothing in here ever throws into the caller or blocks the main thread.

import Foundation

public final class EventLog: @unchecked Sendable {

    public enum EventType: String {
        case action, request, response, fetch, retry, error
        case jobStart = "job_start", jobStep = "job_step", jobEnd = "job_end"
        case auth, system
    }

    public struct Config {
        public var url: String
        public var apiKey: String
        public var project: String
        public var surface: String
        public var env: String
        public var accessToken: (@Sendable () -> String?)?
    }

    public static let shared = EventLog()

    // MARK: configuration

    /// Call once at launch. Safe to call again (replaces config).
    public static func configure(url: String,
                                 apiKey: String,
                                 project: String,
                                 surface: String = EventLog.defaultSurface,
                                 env: String = EventLog.defaultEnv,
                                 accessToken: (@Sendable () -> String?)? = nil) {
        shared.queue.async {
            shared.config = Config(url: url.hasSuffix("/") ? String(url.dropLast()) : url,
                                   apiKey: apiKey, project: project, surface: surface, env: env,
                                   accessToken: accessToken)
            shared.loadPending()
            shared.installLifecycleObservers()
            shared.startTimer()
        }
        shared.log(.system, "app.launch", status: "ok", payload: ["version": appVersion, "build": appBuild, "os": osVersion])
    }

    public static var defaultSurface: String {
        #if os(watchOS)
        return "watchos"
        #else
        return "ios"
        #endif
    }

    public static var defaultEnv: String {
        #if DEBUG
        return "development"
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return "testflight" }
        return "production"
        #endif
    }

    // MARK: public API (static conveniences)

    public static func action(_ name: String, _ payload: [String: Any] = [:]) {
        shared.log(.action, name, status: "ok", payload: payload)
    }

    public static func error(_ error: Error, name: String? = nil, _ payload: [String: Any] = [:]) {
        let ns = error as NSError
        shared.log(.error, name ?? "error.\(ns.domain)", status: "fail", payload: payload,
                   errorCode: "\(ns.domain):\(ns.code)", errorMessage: ns.localizedDescription)
    }

    public static func job(_ name: String) -> Job { Job(name: name) }

    /// Full-control entry point.
    public func log(_ type: EventType,
                    _ name: String,
                    status: String? = nil,
                    payload: [String: Any] = [:],
                    requestId: String? = nil,
                    traceId: String? = nil,
                    attempt: Int? = nil,
                    durationMs: Int? = nil,
                    httpMethod: String? = nil,
                    httpPath: String? = nil,
                    httpStatus: Int? = nil,
                    errorCode: String? = nil,
                    errorMessage: String? = nil) {
        var row: [String: Any] = [
            "event_type": type.rawValue,
            "name": String(name.prefix(300)),
            "device_id": deviceId,
            "session_id": sessionId,
            "actor_type": "device",
            "actor_id": deviceId,
            "app_version": EventLog.appVersion,
            "build": EventLog.appBuild,
            "client_ts": EventLog.iso.string(from: Date()),
            "payload": EventLog.sanitize(payload),
        ]
        if let status = status { row["status"] = status }
        if let requestId = requestId { row["request_id"] = requestId }
        if let traceId = traceId { row["trace_id"] = traceId }
        if let attempt = attempt { row["attempt"] = attempt }
        if let durationMs = durationMs { row["duration_ms"] = durationMs }
        if let httpMethod = httpMethod { row["http_method"] = httpMethod }
        if let httpPath = httpPath { row["http_path"] = String(httpPath.prefix(500)) }
        if let httpStatus = httpStatus { row["http_status"] = httpStatus }
        if let errorCode = errorCode { row["error_code"] = String(errorCode.prefix(200)) }
        if let errorMessage = errorMessage { row["error_message"] = String(errorMessage.prefix(4000)) }
        guard JSONSerialization.isValidJSONObject(row),
              let encoded = try? JSONSerialization.data(withJSONObject: row) else { return }
        queue.async {
            self.buffer.append(encoded)
            if self.buffer.count >= 25 { self.flushLocked() }
        }
    }

    /// Flush now (e.g. before the app is suspended). Completion runs on an arbitrary queue.
    public func flush(_ completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.flushLocked(completion: completion)
        }
    }

    // MARK: logged networking

    /// URLSession.data(for:) with automatic `fetch` / `retry` / `error` rows and
    /// optional retries on transport failure or 5xx.
    @available(iOS 15.0, watchOS 8.0, macOS 12.0, *)
    public func data(for request: URLRequest,
                     session: URLSession = .shared,
                     retries: Int = 0,
                     retryDelay: TimeInterval = 0.5,
                     requestId: String? = nil) async throws -> (Data, URLResponse) {
        var attempt = 0
        let method = request.httpMethod ?? "GET"
        let path = EventLog.hostPath(request.url)
        let rid = requestId ?? EventLog.newId()
        var mutable = request
        mutable.setValue(rid, forHTTPHeaderField: "x-request-id")
        while true {
            attempt += 1
            let started = Date()
            do {
                let (data, response) = try await session.data(for: mutable)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                log(attempt > 1 ? .retry : .fetch, "\(method) \(path)",
                    status: status < 400 ? "ok" : "fail", requestId: rid, attempt: attempt,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    httpMethod: method, httpPath: path, httpStatus: status)
                if status >= 500 && attempt <= retries {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
                    continue
                }
                return (data, response)
            } catch {
                let ns = error as NSError
                log(.error, "\(method) \(path)", status: "fail", requestId: rid, attempt: attempt,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000),
                    httpMethod: method, httpPath: path,
                    errorCode: "\(ns.domain):\(ns.code)", errorMessage: ns.localizedDescription)
                if attempt <= retries {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    // MARK: jobs

    public final class Job {
        public let name: String
        public let traceId = EventLog.newId()
        private let started = Date()
        private var steps = 0
        private let lock = NSLock()

        init(name: String) {
            self.name = name
            EventLog.shared.log(.jobStart, name, status: "pending", traceId: traceId)
        }
        public func step(_ step: String, status: String = "ok", _ payload: [String: Any] = [:]) {
            lock.lock(); steps += 1; let n = steps; lock.unlock()
            EventLog.shared.log(.jobStep, "\(name).\(step)", status: status, payload: payload, traceId: traceId, attempt: n)
        }
        public func end(status: String = "ok", _ payload: [String: Any] = [:]) {
            lock.lock(); let n = steps; lock.unlock()
            var p = payload; p["steps"] = n
            EventLog.shared.log(.jobEnd, name, status: status, payload: p, traceId: traceId,
                                durationMs: Int(Date().timeIntervalSince(started) * 1000))
        }
        public func fail(_ error: Error, _ payload: [String: Any] = [:]) {
            let ns = error as NSError
            EventLog.shared.log(.error, "\(name).error", status: "fail", payload: payload, traceId: traceId,
                                errorCode: "\(ns.domain):\(ns.code)", errorMessage: ns.localizedDescription)
            end(status: "fail")
        }
    }

    // MARK: internals

    private var config: Config?
    private let queue = DispatchQueue(label: "event-log", qos: .utility)
    private var buffer: [Data] = []   // one JSON-encoded event per element (Sendable, cheap to spill)
    private var timer: DispatchSourceTimer?
    private var observersInstalled = false
    private var inFlight = false
    public let sessionId = EventLog.newId()
    public let deviceId: String = {
        let key = "event_log.device_id"
        if let v = UserDefaults.standard.string(forKey: key), !v.isEmpty { return v }
        let v = EventLog.newId()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    private init() {}

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
    }

    private func installLifecycleObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default
        // Raw names so this compiles identically in app, extension and Swift 6 strict-concurrency targets.
        nc.addObserver(forName: Notification.Name("UIApplicationDidBecomeActiveNotification"), object: nil, queue: nil) { [weak self] _ in
            self?.log(.action, "app.foreground", status: "ok")
        }
        nc.addObserver(forName: Notification.Name("UIApplicationWillResignActiveNotification"), object: nil, queue: nil) { [weak self] _ in
            self?.log(.action, "app.background", status: "ok")
            self?.flush()
        }
        nc.addObserver(forName: Notification.Name("UIApplicationWillTerminateNotification"), object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.log(.action, "app.terminate", status: "ok")
            self.queue.sync { self.persistPending() }
        }
    }

    /// Must be called on `queue`.
    private func flushLocked(completion: (@Sendable () -> Void)? = nil) {
        guard let cfg = config, !buffer.isEmpty, !inFlight else { completion?(); return }
        let batch = Array(buffer.prefix(50))
        buffer.removeFirst(batch.count)
        // Stamp project/surface/env by splicing into each pre-encoded object: {"a":1} -> {"project":"x",...,"a":1}
        guard let stamp = try? JSONSerialization.data(withJSONObject: ["project": cfg.project, "surface": cfg.surface, "env": cfg.env]),
              let url = URL(string: "\(cfg.url)/rest/v1/rpc/log_events") else { completion?(); return }
        var body = Data("{\"p\":[".utf8)
        let stampBody = stamp.dropFirst().dropLast()          // strip outer braces
        for (i, row) in batch.enumerated() {
            if i > 0 { body.append(UInt8(ascii: ",")) }
            body.append(UInt8(ascii: "{"))
            body.append(contentsOf: stampBody)
            body.append(UInt8(ascii: ","))
            body.append(contentsOf: row.dropFirst())              // row without its leading "{"
        }
        body.append(contentsOf: Data("]}".utf8))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(cfg.accessToken?() ?? cfg.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        inFlight = true
        let task = URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            guard let self = self else { completion?(); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let failed = error != nil
            self.queue.async {
                self.inFlight = false
                if failed || status >= 500 || status == 0 {
                    // offline or server trouble: put the batch back and spill to disk
                    self.buffer.insert(contentsOf: batch, at: 0)
                    self.persistPending()
                } else if status >= 400 {
                    NSLog("[event_log] rejected %d", status)   // bad rows are dropped, never retried forever
                }
                if !self.buffer.isEmpty && !failed && status >= 200 && status < 400 { self.flushLocked() }
                completion?()
            }
        }
        task.resume()
    }

    private var storeURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("event_log_pending.json")
    }

    /// Must be called on `queue`.
    private func persistPending() {
        guard !buffer.isEmpty else { try? FileManager.default.removeItem(at: storeURL); return }
        var out = Data()
        for row in buffer.suffix(2000) { out.append(row); out.append(UInt8(ascii: "\n")) }
        try? out.write(to: storeURL, options: .atomic)
    }

    /// Must be called on `queue`.
    private func loadPending() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let rows = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        buffer.insert(contentsOf: rows, at: 0)
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: helpers

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static func hostPath(_ url: URL?) -> String {
        guard let url = url else { return "?" }
        return (url.host ?? "") + (url.path.isEmpty ? "/" : url.path)
    }

    /// Makes an arbitrary dictionary JSON-safe and bounded.
    static func sanitize(_ payload: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in payload {
            switch v {
            case let s as String: out[k] = String(s.prefix(2000))
            case is Int, is Double, is Float, is Bool, is NSNumber: out[k] = v
            case let d as Date: out[k] = iso.string(from: d)
            case let u as URL: out[k] = u.absoluteString
            case let dict as [String: Any]: out[k] = sanitize(dict)
            case let arr as [Any]: out[k] = arr.prefix(50).map { item -> Any in
                if let s = item as? String { return String(s.prefix(500)) }
                if item is Int || item is Double || item is Bool || item is NSNumber { return item }
                return String(String(describing: item).prefix(500))
            }
            default: out[k] = String(String(describing: v).prefix(500))
            }
        }
        return out
    }
}

#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Records a `tap.<name>` action whenever the view is tapped, without
    /// interfering with the view's own tap handling.
    func logTap(_ name: String, _ payload: [String: Any] = [:]) -> some View {
        simultaneousGesture(TapGesture().onEnded { EventLog.action(name.hasPrefix("tap.") ? name : "tap.\(name)", payload) })
    }
}
#endif
