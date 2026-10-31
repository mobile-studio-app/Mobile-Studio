import Foundation

// Stand-ins for the app types GitManager.swift uses, so the engine compiles on its own for tests.

final class GitAccountManager {
    struct User {
        let login: String
        let name: String?
    }

    static let shared = GitAccountManager()
    var token: String? = "test-token"
    var currentUser: User? = User(login: "tester", name: "Test User")
}

final class ProjectStore {
    static let shared = ProjectStore()

    func uniqueProjectURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clone-\(name)-\(UUID().uuidString)")
    }
}

func dc_extract_love_archive(_ source: String, _ destination: String, _ error: UnsafeMutablePointer<NSError?>?) -> Bool {
    false
}
