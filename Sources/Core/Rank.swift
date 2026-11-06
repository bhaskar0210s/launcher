// Which apps match a query, best first, and the memory of which app was opened for which query.

struct Match {
    var index: Int        // into the names that were searched
    var score: Int
    var positions: [Int]  // matched characters, for showing them in bold
}

/// The names that match `query`, best first. Letters must start words or follow each other ("gc" finds Google Chrome,
/// "ma" finds Mail but not Terminal); only when no name matches that way do looser matches count. The app opened
/// last time for the same query (`preferred`) comes first; equal scores put the shorter name first, then
/// alphabetical order.
func rank(_ query: String, names: [String], haystacks: [Haystack], preferred: Int? = nil, limit: Int = .max) -> [Match] {
    let q = Query(query)
    if q.isEmpty || limit <= 0 { return [] }
    var matches: [Match] = []
    var score = 0
    var positions: [Int] = []
    for atWords in [true, false] where matches.isEmpty {
        for index in haystacks.indices where q.match(haystacks[index], score: &score, positions: &positions, atWords: atWords) {
            matches.append(Match(index: index, score: index == preferred ? Int.max : score, positions: positions))
        }
    }
    // The app opened last time for these letters stays in the results even when it only matches loosely.
    if let preferred, haystacks.indices.contains(preferred), !matches.contains(where: { $0.index == preferred }),
       q.match(haystacks[preferred], score: &score, positions: &positions) {
        matches.append(Match(index: preferred, score: Int.max, positions: positions))
    }
    matches.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        let x = haystacks[a.index].folded.count, y = haystacks[b.index].folded.count
        if x != y { return x < y }
        return names[a.index] < names[b.index]
    }
    return matches.count > limit ? Array(matches[..<limit]) : matches
}

/// Remembers which app was opened for which query, newest first, so the same letters open the same app next time.
struct Picks: Equatable {
    private(set) var entries: [Entry] = []
    let capacity: Int

    struct Entry: Equatable {
        var query: String  // normalizedQuery()
        var key: String    // the app, by path
    }

    private static let separator: Character = "\u{1F}"

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    /// From the strings `serialized` made; anything malformed is skipped.
    init(serialized: [String], capacity: Int = 200) {
        self.init(capacity: capacity)
        for line in serialized {
            let parts = line.split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  !entries.contains(where: { $0.query == parts[0] }) else { continue }
            entries.append(Entry(query: String(parts[0]), key: String(parts[1])))
            if entries.count == self.capacity { break }
        }
    }

    var serialized: [String] {
        entries.map { $0.query + String(Self.separator) + $0.key }
    }

    func key(for query: String) -> String? {
        let q = normalizedQuery(query)
        return entries.first { $0.query == q }?.key
    }

    mutating func remember(query: String, key: String) {
        let q = normalizedQuery(query)
        guard !q.isEmpty, !key.isEmpty, !q.contains(Self.separator) else { return }
        entries.removeAll { $0.query == q }
        entries.insert(Entry(query: q, key: key), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// Drops what was remembered for an app that is no longer in the list.
    mutating func forget(key: String) {
        entries.removeAll { $0.key == key }
    }
}
