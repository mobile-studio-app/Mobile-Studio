import Foundation

/// The Graph's lanes, as VS Code and git log --graph draw them: each commit sits in a lane,
/// lines carry on to its parents, branches split off and merges join in.
struct GitGraphRow: Equatable {
    /// The commit's lane.
    var node: Int
    /// Lanes that go straight through the row, top to bottom.
    var passThrough: [Int]
    /// Lanes that end at the commit, from the top (branches whose next commit this is).
    var incoming: [Int]
    /// Lanes that start at the commit, going down (its parents).
    var outgoing: [Int]
    /// The lanes still open below the commit, for rows drawn under it (its files).
    var below: [Int]
    var width: Int { ([node] + passThrough + incoming + outgoing + below).max().map { $0 + 1 } ?? 1 }
}

enum GitGraph {
    /// Lanes for `commits`, newest first (as GitRepository.log gives them).
    static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [String?] = []   // the commit each open lane is waiting for
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            // The commit's lane: the first one waiting for it, or a new one (a branch's tip).
            let node: Int
            if let waiting = lanes.firstIndex(where: { $0 == commit.id }) {
                node = waiting
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                node = free
            } else {
                node = lanes.count
                lanes.append(nil)
            }
            var incoming: [Int] = []
            var passThrough: [Int] = []
            for (lane, id) in lanes.enumerated() where id != nil && lane != node {
                if id == commit.id {
                    incoming.append(lane)   // another branch joins here
                    lanes[lane] = nil
                } else {
                    passThrough.append(lane)
                }
            }
            if lanes[node] == commit.id { incoming.append(node) }

            // Parents: the first continues the lane; the others go to lanes waiting for them, or new ones.
            var outgoing: [Int] = []
            lanes[node] = commit.parents.first
            if !commit.parents.isEmpty { outgoing.append(node) }
            for parent in commit.parents.dropFirst() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    outgoing.append(existing)
                } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = parent
                    outgoing.append(free)
                } else {
                    lanes.append(parent)
                    outgoing.append(lanes.count - 1)
                }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            let below = lanes.indices.filter { lanes[$0] != nil }
            rows.append(GitGraphRow(node: node, passThrough: passThrough.filter { lanes.indices.contains($0) && lanes[$0] != nil },
                                    incoming: incoming, outgoing: outgoing, below: below))
        }
        return rows
    }
}
