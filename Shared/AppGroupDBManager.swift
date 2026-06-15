import Foundation
import SQLite3
import OSLog

let dbLogger = Logger(subsystem: "com.sean.PasswordManager", category: "Database")

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
            dbLogger.error("❌ [DB] App Group 容器获取失败，请检查 Capability 配置")
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
            dbLogger.error("❌ [DB] 数据库路径为空，无法打开数据库")
            return
        }
        guard sqlite3_open(self.dbPath, &db) == SQLITE_OK else {
            dbLogger.error("❌ [DB] 无法打开数据库: \(self.dbPath, privacy: .public)")
            return
        }

        execute(sql: "PRAGMA journal_mode=WAL;")
        execute(sql: "PRAGMA busy_timeout = 2000;")
        execute(sql: """
            CREATE TABLE IF NOT EXISTS file_mapping (
                file_name TEXT PRIMARY KEY NOT NULL,
                uid TEXT NOT NULL,
                created_at REAL DEFAULT (julianday('now')),
                last_access_time REAL DEFAULT (julianday('now')),
                last_sync_time REAL
            );
        """)
    }

    private func execute(sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                let error = String(cString: err)
                sqlite3_free(errMsg)
                dbLogger.error("SQLite pragma error: \(error, privacy: .public)")
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
        let sql = "SELECT file_name, uid, last_access_time, last_sync_time FROM file_mapping;"
        var stmt: OpaquePointer?
        var result = ""

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 0),
                   let cUid = sqlite3_column_text(stmt, 1) {
                    let name = String(cString: cName)
                    let uid = String(cString: cUid)
                    let accessTimeValue = sqlite3_column_double(stmt, 2)
                    let accessUnixTimestamp = (accessTimeValue - 2440587.5) * 86400.0
                    let lastAccessTime = String(format: "%.0f", accessUnixTimestamp)
                    
                    let syncTimeValue = sqlite3_column_double(stmt, 3)
                    var lastSyncTime = "未同步"
                    if syncTimeValue > 0 {
                        let syncUnixTimestamp = (syncTimeValue - 2440587.5) * 86400.0
                        lastSyncTime = String(format: "%.0f", syncUnixTimestamp)
                    }
                    
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    let accessDate = Date(timeIntervalSince1970: accessUnixTimestamp)
                    let formattedDate = dateFormatter.string(from: accessDate)
                    result += "📄 文件: \(name) | UID: \(uid) | last_access_time: \(lastAccessTime) (\(formattedDate)) | last_sync_time: \(lastSyncTime)\n"
                }
            }
        }
        sqlite3_finalize(stmt)
        return result.isEmpty ? "数据库当前为空" : result
    }

    /// Insert or replace a record with SQLITE_BUSY retry (2 retries, 300ms interval)
    func upsertRecord(fileName: String, uid: String) -> Bool {
        let normalizedName = normalizeFileName(fileName)
        
        let updateSql = "UPDATE file_mapping SET uid = ?, last_access_time = julianday('now') WHERE file_name = ?;"
        let insertSql = "INSERT INTO file_mapping (file_name, uid, last_access_time, last_sync_time) VALUES (?, ?, julianday('now'), NULL);"

        for attempt in 0..<3 {
            var stmt: OpaquePointer?
            
            if sqlite3_prepare_v2(db, updateSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (uid as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (normalizedName as NSString).utf8String, -1, nil)
                
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                
                if result == SQLITE_DONE {
                    let changes = sqlite3_changes(db)
                    if changes > 0 {
                        let accessTime = queryLastAccessTime(forFileName: fileName)
                        dbLogger.info("✅ [DB] 资产更新成功 | 文件: \(normalizedName, privacy: .public) | last_access_time: \(accessTime ?? "N/A", privacy: .public)")
                        return true
                    }
                }
            }
            
            if sqlite3_prepare_v2(db, insertSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (uid as NSString).utf8String, -1, nil)
                
                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                
                if result == SQLITE_DONE {
                    let accessTime = queryLastAccessTime(forFileName: fileName)
                    dbLogger.info("✅ [DB] 资产插入成功 | 文件: \(normalizedName, privacy: .public) | last_access_time: \(accessTime ?? "N/A", privacy: .public)")
                    return true
                }
            }
            
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        
        dbLogger.error("❌ [DB] 资产写入失败 | 文件: \(normalizedName, privacy: .public)")
        return false
    }
    
    func upsertRecordWithSync(fileName: String, uid: String) -> Bool {
        let normalizedName = normalizeFileName(fileName)

        let sql = "INSERT OR REPLACE INTO file_mapping (file_name, uid, last_access_time, last_sync_time) VALUES (?, ?, julianday('now'), julianday('now'));"

        for attempt in 0..<3 {
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (uid as NSString).utf8String, -1, nil)

                let result = sqlite3_step(stmt)

                if result == SQLITE_DONE {
                    sqlite3_finalize(stmt)
                    let accessTime = queryLastAccessTime(forFileName: fileName)
                    let syncTime = queryLastSyncTime(forFileName: fileName)
                    dbLogger.info("✅ [DB] 扩展同步成功 | 文件: \(normalizedName, privacy: .public) | last_access_time: \(accessTime ?? "N/A", privacy: .public) | last_sync_time: \(syncTime ?? "N/A", privacy: .public)")
                    return true
                } else if result == SQLITE_BUSY {
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

        dbLogger.error("❌ [DB] 扩展同步失败 | 文件: \(normalizedName, privacy: .public)")
        return false
    }
    
    func queryLastSyncTime(forFileName fileName: String) -> String? {
        let normalizedName = normalizeFileName(fileName)

        let sql = "SELECT last_sync_time FROM file_mapping WHERE file_name = ?;"

        var stmt: OpaquePointer?
        var resultTime: String?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                let timeValue = sqlite3_column_double(stmt, 0)
                if timeValue > 0 {
                    let unixTimestamp = (timeValue - 2440587.5) * 86400.0
                    resultTime = String(format: "%.0f", unixTimestamp)
                }
            }
        }

        sqlite3_finalize(stmt)
        return resultTime
    }

    /// Query last_access_time by normalized fileName
    func queryLastAccessTime(forFileName fileName: String) -> String? {
        let normalizedName = normalizeFileName(fileName)

        let sql = "SELECT last_access_time FROM file_mapping WHERE file_name = ?;"

        var stmt: OpaquePointer?
        var resultTime: String?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                let timeValue = sqlite3_column_double(stmt, 0)
                let unixTimestamp = (timeValue - 2440587.5) * 86400.0
                resultTime = String(format: "%.0f", unixTimestamp)
            }
        }

        sqlite3_finalize(stmt)
        return resultTime
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
