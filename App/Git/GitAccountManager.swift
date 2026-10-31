import Foundation

struct GitHubUser: Codable {
    let login: String
    let id: Int
    let name: String?
    let email: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login
        case id
        case name
        case email
        case avatarUrl = "avatar_url"
    }
}

/// Manages GitHub sign-in (browser device flow or a personal access token) and profile state.
/// The token lives in the Keychain; the public profile in UserDefaults.
final class GitAccountManager {
    static let shared = GitAccountManager()

    /// Keychain account for the token; earlier builds kept it under this UserDefaults key.
    private let tokenKey = "duocode.github.token"
    private let userKey = "duocode.github.user"

    private(set) var currentUser: GitHubUser?
    private(set) var token: String?

    var isSignedIn: Bool {
        token != nil && !token!.isEmpty
    }

    var onAuthStateChanged: (() -> Void)?

    private init() {
        loadSavedCredentials()
    }

    private func loadSavedCredentials() {
        // Move a token saved by an earlier build out of UserDefaults.
        if let legacy = UserDefaults.standard.string(forKey: tokenKey) {
            if !legacy.isEmpty { KeychainStore.set(legacy, for: tokenKey) }
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
        if let savedToken = KeychainStore.string(for: tokenKey), !savedToken.isEmpty {
            self.token = savedToken
        }
        if let userData = UserDefaults.standard.data(forKey: userKey),
           let user = try? JSONDecoder().decode(GitHubUser.self, from: userData) {
            self.currentUser = user
        }
    }

    /// Sign in with a GitHub Personal Access Token (classic `repo` or fine-grained `Contents: Read/Write`)
    func signIn(token: String, completion: @escaping (Result<GitHubUser, Error>) -> Void) {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            completion(.failure(NSError(domain: "GitAccount", code: -1, userInfo: [NSLocalizedDescriptionKey: "Token cannot be empty"])))
            return
        }

        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        req.setValue("MobileStudio-iOS", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                let msg = (response as? HTTPURLResponse)?.statusCode == 401
                    ? "Invalid GitHub token. Check permissions and try again."
                    : "GitHub authentication failed."
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "GitAccount", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])))
                }
                return
            }

            do {
                let user = try JSONDecoder().decode(GitHubUser.self, from: data)
                self?.token = cleanToken
                self?.currentUser = user

                if let self {
                    KeychainStore.set(cleanToken, for: self.tokenKey)
                    UserDefaults.standard.set(data, forKey: self.userKey)
                }

                DispatchQueue.main.async {
                    self?.onAuthStateChanged?()
                    completion(.success(user))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    func signOut() {
        token = nil
        currentUser = nil
        KeychainStore.remove(tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        onAuthStateChanged?()
    }
}
