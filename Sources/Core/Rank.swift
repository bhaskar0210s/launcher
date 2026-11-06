// Which apps match a query and in what order, and the memory of which apps were opened most recently.

struct Match {
    var index: Int        // into the names that were searched
    var score: Int
    var positions: [Int]  // matched characters, for showing them in bold
}

/// The names that match `query`, in the order they are offered.
///
/// Letters must start words or follow each other ("gc" finds Google Chrome, "ma" finds Mail but not Terminal); only
/// when no name matches that way do looser matches count. Among the matches, the apps opened before come first, the
/// most recently opened first: the previous selection wins, whatever the letters. `recency[i]` is that place for
/// name `i` (0 for the last one opened), or nil when it was never opened. The others follow by how well they match,
/// then the shorter name, then alphabetical order.
func rank(_ query: String, names: [String], haystacks: [Haystack], recency: [Int?] = [], limit: Int = .max) -> [Match] {
    let q = Query(query)
    if q.isEmpty || limit <= 0 { return [] }
    var matches: [Match] = []
    var score = 0
    var positions: [Int] = []
    for atWords in [true, false] where matches.isEmpty {
        for index in haystacks.indices where q.match(haystacks[index], score: &score, positions: &positions, atWords: atWords) {
            matches.append(Match(index: index, score: score, positions: positions))
        }
    }
    func place(_ index: Int) -> Int { (recency.indices.contains(index) ? recency[index] : nil) ?? Int.max }
    matches.sort { a, b in
        let x = place(a.index), y = place(b.index)
        if x != y { return x < y }
        if a.score != b.score { return a.score > b.score }
        let m = haystacks[a.index].folded.count, n = haystacks[b.index].folded.count
        if m != n { return m < n }
        return names[a.index] < names[b.index]
    }
    return matches.count > limit ? Array(matches[..<limit]) : matches
}

/// The apps opened from Launcher, most recent first. Opening one moves it to the front.
struct Recents: Equatable {
    private(set) var paths: [String] = []
    let capacity: Int

    init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    /// From the list `paths` saved; empty and repeated entries are skipped.
    init(paths saved: [String], capacity: Int = 500) {
        self.init(capacity: capacity)
        var seen = Set<String>()
        for path in saved where !path.isEmpty && seen.insert(path).inserted {
            paths.append(path)
            if paths.count == self.capacity { break }
        }
    }

    /// From the memory of earlier versions, which kept the app opened for each query ("query␟path", newest first):
    /// the apps in the order they were last opened.
    init(picks: [String], capacity: Int = 500) {
        self.init(paths: picks.compactMap { line in
            guard let separator = line.firstIndex(of: "\u{1F}") else { return nil }
            return String(line[line.index(after: separator)...])
        }, capacity: capacity)
    }

    /// 0 for the app opened last, 1 for the one before, nil when it was never opened.
    func place(of path: String) -> Int? {
        paths.firstIndex(of: path)
    }

    mutating func record(_ path: String) {
        guard !path.isEmpty else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > capacity { paths.removeLast(paths.count - capacity) }
    }

    /// An app taken out of the list loses its place.
    mutating func forget(_ path: String) {
        paths.removeAll { $0 == path }
    }
}
