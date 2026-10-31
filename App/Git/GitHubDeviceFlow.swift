import Foundation

/// GitHub OAuth app used for "Sign in with GitHub".
///
/// Register one at github.com → Settings → Developer settings → OAuth Apps → New OAuth App
/// (any homepage/callback URL), tick "Enable Device Flow", and paste its Client ID below.
/// A client ID is public; the device flow needs no client secret, so none is stored in the app.
enum GitHubOAuthConfig {
    static let clientID = "Ov23liRPswfS4dhKeDXo"
    /// `repo` grants access to private repositories (clone and push).
    static let scope = "repo"

    static var isConfigured: Bool { !clientID.isEmpty }
}

/// GitHub's OAuth device flow: the user enters a short code on github.com/login/device
/// while the app polls for the access token.
final class GitHubDeviceFlow {
    struct Code {
        let userCode: String
        let verificationURL: URL
        fileprivate let deviceCode: String
        fileprivate let interval: TimeInterval
        fileprivate let expiresAt: Date
    }

    private var pollTask: Task<Void, Never>?

    deinit { cancel() }

    /// Step 1: ask GitHub for a user code to show.
    func requestCode() async throws -> Code {
        let json = try await post("https://github.com/login/device/code", [
            "client_id": GitHubOAuthConfig.clientID,
            "scope": GitHubOAuthConfig.scope,
        ])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw Self.error(json["error_description"] as? String ?? "GitHub didn't return a sign-in code.")
        }
        let interval = (json["interval"] as? Double) ?? 5
        let expiresIn = (json["expires_in"] as? Double) ?? 900
        return Code(userCode: userCode, verificationURL: uri, deviceCode: deviceCode,
                    interval: interval, expiresAt: Date().addingTimeInterval(expiresIn))
    }

    /// Step 2: poll until the user approves (or denies, or the code expires). Calls back on the main queue.
    func waitForToken(_ code: Code, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        pollTask = Task { [weak self] in
            var interval = code.interval
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                if Date() > code.expiresAt {
                    await Self.finish(completion, .failure(Self.error("The sign-in code expired. Try again.")))
                    return
                }
                do {
                    guard let self else { return }
                    let json = try await self.post("https://github.com/login/oauth/access_token", [
                        "client_id": GitHubOAuthConfig.clientID,
                        "device_code": code.deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    ])
                    if let token = json["access_token"] as? String {
                        await Self.finish(completion, .success(token))
                        return
                    }
                    switch json["error"] as? String {
                    case "authorization_pending":
                        continue
                    case "slow_down":
                        interval = (json["interval"] as? Double) ?? interval + 5
                    case "access_denied":
                        await Self.finish(completion, .failure(Self.error("Sign-in was cancelled on GitHub.")))
                        return
                    case "expired_token":
                        await Self.finish(completion, .failure(Self.error("The sign-in code expired. Try again.")))
                        return
                    default:
                        let message = json["error_description"] as? String ?? "GitHub sign-in failed."
                        await Self.finish(completion, .failure(Self.error(message)))
                        return
                    }
                } catch {
                    // Transient network trouble: keep polling until the code expires.
                    continue
                }
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Helpers

    private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @MainActor
    private static func finish(_ completion: (Result<String, Error>) -> Void, _ result: Result<String, Error>) {
        completion(result)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "GitHubSignIn", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
