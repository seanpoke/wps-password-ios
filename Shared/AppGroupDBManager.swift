import Foundation
import SQLite3

/// AppGroup shared WAL SQLite manager using native libsqlite3
/// App Group ID: group.com.sean.passwordmanager
final class AppGroupDBManager {

    static let shared = AppGroupDBManager()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.sean.PasswordManager"
        ) else {
            print("❌ [DB] App Group 容器获取失败，请检查 Capability 配置")
            self.dbPath = ""
            return
        }
        let documentsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: documentsURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        self.dbPath = documentsURL.appendingPathComponent("file_mapping.sqlite").path
        openDatabase()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        guard !dbPath.isEmpty else {
            print("❌ [DB] 数据库路径为空，无法打开数据库")
            return
        }
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("❌ [DB] 无法打开数据库: \(dbPath)")
            return
        }

        // Enable WAL mode
        execute(pragma: "PRAGMA journal_mode=WAL;")
        // Set busy timeout to 2000ms
        execute(pragma: "PRAGMA busy_timeout = 2000;")

        // Create table if not exists
        execute(pragma: """
            CREATE TABLE IF NOT EXISTS file_mapping (
                file_name TEXT PRIMARY KEY NOT NULL,
                uid TEXT NOT NULL,
                created_at REAL DEFAULT (julianday('now'))
            );
        """)
    }

    private func execute(pragma sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                let error = String(cString: err)
                sqlite3_free(errMsg)
                print("SQLite pragma error: \(error)")
            }
        }
    }

    // MARK: - Primary Key Normalization

    /// Normalize fileName: trim whitespace and convert to lowercase
    private func normalizeFileName(_ fileName: String) -> String {
        return fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - CRUD Operations with Retry Logic

    func saveFileMapping(fileName: String, ldapUID: String, passwordMock: String) {
        let _ = upsertRecord(fileName: fileName, uid: ldapUID)
    }

    func fetchAllLog() -> String {
        let sql = "SELECT file_name, uid FROM file_mapping;"
        var stmt: OpaquePointer?
        var result = ""

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 0),
                   let cUid = sqlite3_column_text(stmt, 1) {
                    let name = String(cString: cName)
                    let uid = String(cString: cUid)
                    result += "📄 文件: \(name) | UID: \(uid)\n"
                }
            }
        }
        sqlite3_finalize(stmt)
        return result.isEmpty ? "数据库当前为空" : result
    }

    /// Insert or replace a record with SQLITE_BUSY retry (2 retries, 300ms interval)
    func upsertRecord(fileName: String, uid: String) -> Bool {
        let normalizedName = normalizeFileName(fileName)

        let sql = "INSERT OR REPLACE INTO file_mapping (file_name, uid) VALUES (?, ?);"

        for attempt in 0..<3 {
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (uid as NSString).utf8String, -1, nil)

                let result = sqlite3_step(stmt)

                if result == SQLITE_DONE {
                    sqlite3_finalize(stmt)
                    return true
                } else if result == SQLITE_BUSY {
                    // Retry logic: 2 retries with 300ms interval
                    if attempt < 2 {
                        sqlite3_finalize(stmt)
                        Thread.sleep(forTimeInterval: 0.3)
                        continue
                    }
                }

                sqlite3_finalize(stmt)
            }

            break
        }

        return false
    }

    /// Query UID by normalized fileName
    func queryUID(forFileName fileName: String) -> String? {
        let normalizedName = normalizeFileName(fileName)

        let sql = "SELECT uid FROM file_mapping WHERE file_name = ?;"

        var stmt: OpaquePointer?
        var resultUID: String?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    resultUID = String(cString: cString)
                }
            }
        }

        sqlite3_finalize(stmt)
        return resultUID
    }

    /// Delete record by normalized fileName
    func deleteRecord(fileName: String) -> Bool {
        let normalizedName = normalizeFileName(fileName)

        let sql = "DELETE FROM file_mapping WHERE file_name = ?;"

        var stmt: OpaquePointer?
        var success = false

        for attempt in 0..<3 {
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)

                let result = sqlite3_step(stmt)
                success = (result == SQLITE_DONE)

                sqlite3_finalize(stmt)
            }

            if success { break }

            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        return success
    }
}
