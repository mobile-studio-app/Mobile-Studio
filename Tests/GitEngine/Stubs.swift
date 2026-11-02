import Foundation

// Stand-ins for the app types the git code uses, so it compiles on its own for tests.

final class GitAccountManager {
    struct User {
        let login: String
        let name: String?
    }

    static let shared = GitAccountManager()
    var token: String? = "test-token"
    var currentUser: User? = User(login: "tester", name: "Test User")
}
