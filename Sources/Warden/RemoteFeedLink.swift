import Foundation
import WardenCore

/// The Mac decrypts and interprets telemetry. The relay handles only pairing hashes and opaque packets.
@MainActor
final class RemoteFeedLink {
    private let feed: RemoteFeed
    private let usageProviders: [String]
    private var challenge = RemotePhoneCrypto.token()
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private var sequence = 0

    init(feed: RemoteFeed, usageProviders: [String], interval: TimeInterval = 20) {
        self.feed = feed; self.usageProviders = usageProviders; self.interval = interval
    }

    func start(snapshot: @escaping (RemoteSnapshot) -> Void, failed: @escaping (String) -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            var registered = false
            while !Task.isCancelled {
                do {
                    if !registered {
                        challenge = RemotePhoneCrypto.token(); sequence = 0
                        _ = try await Self.request(feed, method: "PUT", value: ["publisherToken": feed.publisherToken,
                            "challenge": challenge, "usageProviders": usageProviders])
                        registered = true
                    }
                    let value = try await Self.request(feed, method: "GET")
                    if let packet = value["box"] as? String {
                        let data = try feed.open(packet)
                        guard data.count <= RemoteSSHStream.frameLimit + 4096 else { throw Self.invalidPacket }
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
                        let envelope = try decoder.decode(RemoteFeedEnvelope.self, from: data)
                        if envelope.challenge == challenge, envelope.sequence > sequence, envelope.snapshot.version == 1 {
                            sequence = envelope.sequence
                            if !Task.isCancelled { snapshot(envelope.snapshot) }
                        }
                    }
                } catch {
                    registered = false
                    if !Task.isCancelled { failed("HTTPS feed unavailable: \(error.localizedDescription)") }
                }
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    static func request(_ feed: RemoteFeed, method: String, value: [String: Any]? = nil, paused: Bool? = nil) async throws -> [String: Any] {
        var allowLocal = false
        #if DEBUG
        allowLocal = true
        #endif
        guard feed.valid, let base = RemoteFeed.url(feed.relay, allowLocalHTTP: allowLocal) else { throw URLError(.badURL) }
        var request = URLRequest(url: base.appendingPathComponent("v1/feeds/" + feed.room))
        request.httpMethod = method
        request.setValue("Bearer " + feed.readerToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let paused { request.setValue(paused ? "1" : "0", forHTTPHeaderField: "X-Warden-Paused") }
        if let value { request.httpBody = try JSONSerialization.data(withJSONObject: value) }
        let (data, response) = try await RemoteFeedRequest().run(request)
        guard (200..<300).contains(response.statusCode) else {
            throw NSError(domain: "WardenFeed", code: response.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Relay returned HTTP \(response.statusCode)."])
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalidPacket }
        return result
    }

    private static var invalidPacket: NSError {
        NSError(domain: "WardenFeed", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted telemetry."])
    }
}

/// Bound a response as it arrives, and never forward a pairing credential to a redirect target.
private final class RemoteFeedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var data = Data()
    private var response: HTTPURLResponse?

    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(response.expectedContentLength > 3_000_000 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 3_000_000 else { finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((data, response))) }
        else { finish(.failure(URLError(.badServerResponse))) }
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.invalidateAndCancel(); session = nil
        continuation.resume(with: result)
    }
}
