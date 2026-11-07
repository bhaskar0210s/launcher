// Notes from Apple's Notes app. Their titles are read from Notes' database, which macOS opens only to apps with Full
// Disk Access, for choosing notes in Settings; a note opens with its applenotes: link, which needs no permission.

import Darwin
import SQLite3

/// A note as Pounce keeps it: Notes' identifier for it and its title (the note's first line).
struct Note: Equatable, Sendable {
    let id: String
    var title: String
}

enum NotesError: Error, Equatable, Sendable {
    case noAccess    // macOS keeps the database from Pounce: it needs Full Disk Access
    case missing     // there is no Notes database: Notes was never used on this Mac
    case unreadable  // the database isn't laid out as Pounce expects (a later Notes changed it)
}

/// The link that opens a note in Notes, or nil when `id` isn't a note identifier (a UUID).
func noteLink(_ id: String) -> String? {
    // 8-4-4-4-12 hexadecimal digits.
    var count = 0
    for byte in id.utf8 {
        let dash = count == 8 || count == 13 || count == 18 || count == 23
        let hex = (byte >= 48 && byte <= 57) || (byte | 0x20 >= 97 && byte | 0x20 <= 102)
        guard dash ? byte == 45 : hex else { return nil }
        count += 1
    }
    return count == 36 ? "applenotes:note/" + id : nil
}

/// A title as Pounce shows it: no spaces around it, and no stand-ins for attachments (U+FFFC).
func noteTitle(_ text: String) -> String {
    var scalars = decodeUTF8(Array(text.utf8)).filter { $0 != 0xFFFC }
    while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
    while let last = scalars.last, isSpace(last) { scalars.removeLast() }
    var title = ""
    title.unicodeScalars.append(contentsOf: scalars.compactMap(Unicode.Scalar.init))
    return title
}

/// The notes in Notes, the most recently changed first: the ones Notes lists, so not those deleted or in Recently
/// Deleted, and not the empty stand-ins its database also holds.
func readNotes(at path: String) -> Result<[Note], NotesError> {
    // macOS answers an app without access with EPERM: tell that apart from a missing file before SQLite hides it.
    let file = open(path, O_RDONLY)
    if file < 0 {
        let error = errno
        return .failure(error == ENOENT ? .missing : error == EPERM || error == EACCES ? .noAccess : .unreadable)
    }
    close(file)

    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        sqlite3_close(database)
        return .failure(.unreadable)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 500)                                     // Notes may be saving a note
    sqlite3_exec(database, "PRAGMA cache_size = -256", nil, nil, nil)      // a few titles need little memory

    let query = """
        SELECT n.ZIDENTIFIER, n.ZTITLE1 FROM ZICCLOUDSYNCINGOBJECT AS n
        JOIN ZICCLOUDSYNCINGOBJECT AS f ON f.Z_PK = n.ZFOLDER
        WHERE n.Z_ENT = (SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'ICNote')
          AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0 AND IFNULL(f.ZMARKEDFORDELETION, 0) = 0
          AND IFNULL(f.ZFOLDERTYPE, 0) <> 1
        ORDER BY n.ZMODIFICATIONDATE1 DESC
        """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
        sqlite3_finalize(statement)
        return .failure(.unreadable)
    }
    defer { sqlite3_finalize(statement) }

    var notes: [Note] = []
    var seen = Set<String>()
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { break }
        guard step == SQLITE_ROW else { return .failure(.unreadable) }
        guard let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { continue }
        let note = Note(id: String(cString: id), title: noteTitle(String(cString: title)))
        if noteLink(note.id) != nil, !note.title.isEmpty, seen.insert(note.id).inserted { notes.append(note) }
    }
    return .success(notes)
}
