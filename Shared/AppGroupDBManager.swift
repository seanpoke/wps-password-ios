import Foundation
import SQLite3
import OSLog

let dbLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "Database")

struct FileMappingRecord {
    let uid: String
    let file_name: String
    let password_hash: String
    let last_access_time: Int64
    let file_size: Int64
    let is_local_vault: Int
}

final class AppGroupDBManager {

    static let shared = AppGroupDBManager()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.greenet.PasswordManager"
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
            CREATE TABLE IF NOT EXISTS file_mapping_table (
                uid TEXT PRIMARY KEY,
                file_name TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                last_access_time INTEGER NOT NULL,
                file_size INTEGER NOT NULL,
                is_local_vault INTEGER DEFAULT 0
            );
        """)
        execute(sql: "CREATE INDEX IF NOT EXISTS idx_filename_size ON file_mapping_table(file_name, file_size);")
        execute(sql: "CREATE INDEX IF NOT EXISTS idx_access_time ON file_mapping_table(last_access_time);")
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

    private func normalizeFileName(_ fileName: String) -> String {
        return fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func saveFileMapping(fileName: String, uid: String, passwordHash: String, fileSize: Int64, isLocalVault: Int) -> Bool {
        return upsertRecord(uid: uid, fileName: fileName, passwordHash: passwordHash, fileSize: fileSize, isLocalVault: isLocalVault)
    }

    func fetchAllLog() -> String {
        let sql = "SELECT uid, file_name, password_hash, last_access_time, file_size, is_local_vault FROM file_mapping_table ORDER BY last_access_time DESC;"
        var stmt: OpaquePointer?
        var result = ""

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 0),
                   let cName = sqlite3_column_text(stmt, 1),
                   let cHash = sqlite3_column_text(stmt, 2) {
                    let uid = String(cString: cUid)
                    let name = String(cString: cName)
                    let hash = String(cString: cHash)
                    let accessTime = sqlite3_column_int64(stmt, 3)
                    let fileSize = sqlite3_column_int64(stmt, 4)
                    let isLocal = sqlite3_column_int(stmt, 5)

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    let accessDate = Date(timeIntervalSince1970: TimeInterval(accessTime))
                    let formattedDate = dateFormatter.string(from: accessDate)

                    result += "📄 文件: \(name) | UID: \(uid) | Hash: \(hash.prefix(8))... | last_access: \(accessTime) (\(formattedDate)) | size: \(fileSize) | vault: \(isLocal)\n"
                }
            }
        }
        sqlite3_finalize(stmt)
        return result.isEmpty ? "数据库当前为空" : result
    }

    func upsertRecord(uid: String, fileName: String, passwordHash: String, fileSize: Int64, isLocalVault: Int) -> Bool {
        let normalizedName = normalizeFileName(fileName)
        let timestamp = Int64(Date().timeIntervalSince1970)

        let sql = "INSERT OR REPLACE INTO file_mapping_table (uid, file_name, password_hash, last_access_time, file_size, is_local_vault) VALUES (?, ?, ?, ?, ?, ?);"

        for attempt in 0..<3 {
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (uid as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (normalizedName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (passwordHash as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 4, timestamp)
                sqlite3_bind_int64(stmt, 5, fileSize)
                sqlite3_bind_int(stmt, 6, Int32(isLocalVault))

                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)

                if result == SQLITE_DONE {
                    dbLogger.info("✅ [DB] 资产写入成功 | UID: \(uid, privacy: .public) | 文件: \(normalizedName, privacy: .public) | vault: \(isLocalVault)")
                    return true
                }
            }

            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        dbLogger.error("❌ [DB] 资产写入失败 | UID: \(uid, privacy: .public) | 文件: \(normalizedName, privacy: .public)")
        return false
    }

    func updateAccessTime(uid: String) -> Bool {
        let timestamp = Int64(Date().timeIntervalSince1970)
        let sql = "UPDATE file_mapping_table SET last_access_time = ? WHERE uid = ?;"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, timestamp)
            sqlite3_bind_text(stmt, 2, (uid as NSString).utf8String, -1, nil)

            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if result == SQLITE_DONE {
                let changes = sqlite3_changes(db)
                if changes > 0 {
                    dbLogger.info("✅ [DB] 访问时间更新成功 | UID: \(uid, privacy: .public)")
                    return true
                }
            }
        }

        dbLogger.error("❌ [DB] 访问时间更新失败 | UID: \(uid, privacy: .public)")
        return false
    }

    func updateVaultStatus(uid: String, isLocalVault: Int) -> Bool {
        let sql = "UPDATE file_mapping_table SET is_local_vault = ? WHERE uid = ?;"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(isLocalVault))
            sqlite3_bind_text(stmt, 2, (uid as NSString).utf8String, -1, nil)

            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if result == SQLITE_DONE {
                let changes = sqlite3_changes(db)
                if changes > 0 {
                    dbLogger.info("✅ [DB] Vault状态更新成功 | UID: \(uid, privacy: .public) | vault: \(isLocalVault)")
                    return true
                }
            }
        }

        dbLogger.error("❌ [DB] Vault状态更新失败 | UID: \(uid, privacy: .public)")
        return false
    }

    func queryUID(forFileName fileName: String) -> String? {
        let normalizedName = normalizeFileName(fileName)

        let sql = "SELECT uid FROM file_mapping_table WHERE file_name = ?;"

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

    func queryRecordByUID(uid: String) -> FileMappingRecord? {
        let sql = "SELECT uid, file_name, password_hash, last_access_time, file_size, is_local_vault FROM file_mapping_table WHERE uid = ?;"

        var stmt: OpaquePointer?
        var record: FileMappingRecord?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (uid as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 0),
                   let cName = sqlite3_column_text(stmt, 1),
                   let cHash = sqlite3_column_text(stmt, 2) {
                    record = FileMappingRecord(
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password_hash: String(cString: cHash),
                        last_access_time: sqlite3_column_int64(stmt, 3),
                        file_size: sqlite3_column_int64(stmt, 4),
                        is_local_vault: Int(sqlite3_column_int(stmt, 5))
                    )
                }
            }
        }

        sqlite3_finalize(stmt)
        return record
    }

    func queryRecordsByFileName(fileName: String) -> [FileMappingRecord] {
        let normalizedName = normalizeFileName(fileName)

        let sql = "SELECT uid, file_name, password_hash, last_access_time, file_size, is_local_vault FROM file_mapping_table WHERE file_name LIKE ? ORDER BY last_access_time DESC;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let likePattern = "%" + normalizedName + "%"
            sqlite3_bind_text(stmt, 1, (likePattern as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 0),
                   let cName = sqlite3_column_text(stmt, 1),
                   let cHash = sqlite3_column_text(stmt, 2) {
                    records.append(FileMappingRecord(
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password_hash: String(cString: cHash),
                        last_access_time: sqlite3_column_int64(stmt, 3),
                        file_size: sqlite3_column_int64(stmt, 4),
                        is_local_vault: Int(sqlite3_column_int(stmt, 5))
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)
        return records
    }

    func queryTopActiveRecords(limit: Int) -> [FileMappingRecord] {
        let sql = "SELECT uid, file_name, password_hash, last_access_time, file_size, is_local_vault FROM file_mapping_table ORDER BY last_access_time DESC LIMIT ?;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 0),
                   let cName = sqlite3_column_text(stmt, 1),
                   let cHash = sqlite3_column_text(stmt, 2) {
                    records.append(FileMappingRecord(
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password_hash: String(cString: cHash),
                        last_access_time: sqlite3_column_int64(stmt, 3),
                        file_size: sqlite3_column_int64(stmt, 4),
                        is_local_vault: Int(sqlite3_column_int(stmt, 5))
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)
        return records
    }

    func queryAllLocalVaultRecords() -> [FileMappingRecord] {
        let sql = "SELECT uid, file_name, password_hash, last_access_time, file_size, is_local_vault FROM file_mapping_table WHERE is_local_vault = 1 ORDER BY last_access_time ASC;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 0),
                   let cName = sqlite3_column_text(stmt, 1),
                   let cHash = sqlite3_column_text(stmt, 2) {
                    records.append(FileMappingRecord(
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password_hash: String(cString: cHash),
                        last_access_time: sqlite3_column_int64(stmt, 3),
                        file_size: sqlite3_column_int64(stmt, 4),
                        is_local_vault: Int(sqlite3_column_int(stmt, 5))
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)
        return records
    }

    func deleteRecord(uid: String) -> Bool {
        let sql = "DELETE FROM file_mapping_table WHERE uid = ?;"

        var stmt: OpaquePointer?
        var success = false

        for attempt in 0..<3 {
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (uid as NSString).utf8String, -1, nil)

                let result = sqlite3_step(stmt)
                success = (result == SQLITE_DONE)

                sqlite3_finalize(stmt)
            }

            if success { break }

            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        if success {
            dbLogger.info("✅ [DB] 记录删除成功 | UID: \(uid, privacy: .public)")
        } else {
            dbLogger.error("❌ [DB] 记录删除失败 | UID: \(uid, privacy: .public)")
        }

        return success
    }

    func deleteRecordByFileName(fileName: String) -> Bool {
        let normalizedName = normalizeFileName(fileName)
        let sql = "DELETE FROM file_mapping_table WHERE file_name = ?;"

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