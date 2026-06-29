import Foundation
import SQLite3
import OSLog

let dbLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "Database")

struct FileMappingRecord: Identifiable {
    let id: Int64
    let uid: String
    let file_name: String
    let password: String
    let create_time: Int64
    let update_time: Int64
    let last_access_time: Int64
    let file_size: Int64
    let is_local_vault: Int
    let owner_account: String
}

struct GlobalConfigRecord: Identifiable {
    let key: String
    let value: String
    let remark: String

    var id: String { key }
}

enum GlobalConfigKey {
    static let token = "token"
    static let name = "name"
    static let role = "role"
    static let account = "account"
    static let password = "password"
    static let domain = "domain"
    static let port = "port"
    static let publicKey = "public_key"
    static let keyVersion = "key_version"
    static let rememberPassword = "remember_password"

    static let allKeys: [(key: String, remark: String)] = [
        (token, "用户登录后的访问令牌，用于后续接口身份校验"),
        (name, "用户姓名"),
        (role, "用户角色"),
        (account, "登录账号"),
        (password, "登录密码（仅在勾选记住密码时保存）"),
        (domain, "服务器域名或IP"),
        (port, "服务器端口"),
        (publicKey, "服务端公钥"),
        (keyVersion, "密钥版本号"),
        (rememberPassword, "是否记住密码")
    ]
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
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(self.dbPath, &db, flags, nil) == SQLITE_OK else {
            dbLogger.error("❌ [DB] 无法打开数据库: \(self.dbPath, privacy: .public)")
            return
        }

        execute(sql: "PRAGMA journal_mode=WAL;")
        execute(sql: "PRAGMA busy_timeout = 2000;")
        execute(sql: """
            CREATE TABLE IF NOT EXISTS file_mapping_table (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                uid TEXT NOT NULL,
                file_name TEXT NOT NULL,
                password TEXT NOT NULL,
                create_time INTEGER NOT NULL,
                update_time INTEGER NOT NULL,
                last_access_time INTEGER NOT NULL,
                file_size INTEGER NOT NULL,
                is_local_vault INTEGER DEFAULT 0,
                owner_account TEXT NOT NULL DEFAULT ''
            );
        """)
        execute(sql: "ALTER TABLE file_mapping_table ADD COLUMN owner_account TEXT NOT NULL DEFAULT '';")
        execute(sql: "ALTER TABLE file_mapping_table RENAME COLUMN password_hash TO password;")
        execute(sql: "CREATE INDEX IF NOT EXISTS idx_uid ON file_mapping_table(uid);")
        execute(sql: "CREATE INDEX IF NOT EXISTS idx_access_time ON file_mapping_table(last_access_time);")
        execute(sql: "CREATE INDEX IF NOT EXISTS idx_update_time ON file_mapping_table(update_time);")
        execute(sql: "CREATE INDEX IF NOT EXISTS idx_filename_size ON file_mapping_table(file_name, file_size);")
        execute(sql: """
            CREATE TABLE IF NOT EXISTS global_config_table (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL DEFAULT '',
                remark TEXT NOT NULL DEFAULT ''
            );
        """)
        initializeDefaultConfigs()
    }

    private func initializeDefaultConfigs() {
        let defaultValues: [String: String] = [
            GlobalConfigKey.publicKey: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEuY2/Hz7c7gM0O8P/8VYjDasWhdW4jyS99+Xwyghe+CVFko7KPeamzaOsUffIHQz0VAA8RH9MV1BYyuZAJ7X05Q==",
            GlobalConfigKey.keyVersion: "default"
        ]
        for (key, remark) in GlobalConfigKey.allKeys {
            let defaultValue = defaultValues[key] ?? ""
            let sql = "INSERT OR IGNORE INTO global_config_table (key, value, remark) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (defaultValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (remark as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    dbLogger.error("❌ [DB] 默认配置初始化失败 | key: \(key, privacy: .public)")
                }
                sqlite3_finalize(stmt)
            }
        }
        dbLogger.info("✅ [DB] 全局配置默认key已初始化 | 共 \(GlobalConfigKey.allKeys.count) 项")
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
        return fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveFileMapping(fileName: String, uid: String, passwordHash: String, fileSize: Int64, isLocalVault: Int, ownerAccount: String = "") -> Bool {
        let existingRecords = queryRecordsByUID(uid: uid)
        if let firstRecord = existingRecords.first {
            return updateRecord(
                id: firstRecord.id,
                fileName: fileName,
                passwordHash: passwordHash,
                fileSize: fileSize,
                isLocalVault: isLocalVault
            )
        } else {
            return insertRecord(
                uid: uid,
                fileName: fileName,
                passwordHash: passwordHash,
                fileSize: fileSize,
                isLocalVault: isLocalVault,
                ownerAccount: ownerAccount
            )
        }
    }

    func insertRecord(uid: String, fileName: String, passwordHash: String, fileSize: Int64, isLocalVault: Int, ownerAccount: String = "") -> Bool {
        let normalizedName = normalizeFileName(fileName)
        let timestamp = Int64(Date().timeIntervalSince1970)

        let sql = "INSERT INTO file_mapping_table (uid, file_name, password, create_time, update_time, last_access_time, file_size, is_local_vault, owner_account) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"

        for attempt in 0..<3 {
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (uid as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (normalizedName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (passwordHash as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 4, timestamp)
                sqlite3_bind_int64(stmt, 5, timestamp)
                sqlite3_bind_int64(stmt, 6, timestamp)
                sqlite3_bind_int64(stmt, 7, fileSize)
                sqlite3_bind_int(stmt, 8, Int32(isLocalVault))
                sqlite3_bind_text(stmt, 9, (ownerAccount as NSString).utf8String, -1, nil)

                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)

                if result == SQLITE_DONE {
                    let newId = sqlite3_last_insert_rowid(db)
                    dbLogger.info("✅ [DB] 记录插入成功 | ID: \(newId) | UID: \(uid, privacy: .public) | 文件: \(normalizedName, privacy: .public) | vault: \(isLocalVault) | owner: \(ownerAccount, privacy: .public)")
                    return true
                }
            }

            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        dbLogger.error("❌ [DB] 记录插入失败 | UID: \(uid, privacy: .public) | 文件: \(normalizedName, privacy: .public)")
        return false
    }

    func updateRecord(id: Int64, fileName: String, passwordHash: String, fileSize: Int64, isLocalVault: Int) -> Bool {
        let normalizedName = normalizeFileName(fileName)
        let timestamp = Int64(Date().timeIntervalSince1970)

        let sql = "UPDATE file_mapping_table SET file_name = ?, password = ?, update_time = ?, last_access_time = ?, file_size = ?, is_local_vault = ? WHERE id = ?;"

        for attempt in 0..<3 {
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (normalizedName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (passwordHash as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 3, timestamp)
                sqlite3_bind_int64(stmt, 4, timestamp)
                sqlite3_bind_int64(stmt, 5, fileSize)
                sqlite3_bind_int(stmt, 6, Int32(isLocalVault))
                sqlite3_bind_int64(stmt, 7, id)

                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)

                if result == SQLITE_DONE {
                    let changes = sqlite3_changes(db)
                    if changes > 0 {
                        dbLogger.info("✅ [DB] 记录更新成功 | ID: \(id) | 文件: \(normalizedName, privacy: .public) | vault: \(isLocalVault)")
                        return true
                    }
                }
            }

            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        dbLogger.error("❌ [DB] 记录更新失败 | ID: \(id)")
        return false
    }

    func upsertRecord(uid: String, fileName: String, passwordHash: String, fileSize: Int64, isLocalVault: Int, ownerAccount: String = "") -> Bool {
        let existingRecords = queryRecordsByUID(uid: uid)
        if let firstRecord = existingRecords.first {
            return updateRecord(
                id: firstRecord.id,
                fileName: fileName,
                passwordHash: passwordHash,
                fileSize: fileSize,
                isLocalVault: isLocalVault
            )
        } else {
            return insertRecord(
                uid: uid,
                fileName: fileName,
                passwordHash: passwordHash,
                fileSize: fileSize,
                isLocalVault: isLocalVault,
                ownerAccount: ownerAccount
            )
        }
    }

    func updateOwnerAccount(uid: String, ownerAccount: String) -> Bool {
        let records = queryRecordsByUID(uid: uid)
        if records.isEmpty {
            dbLogger.warning("⚠️ [DB] 更新owner_account失败，未找到UID: \(uid, privacy: .public)")
            return false
        }

        let timestamp = Int64(Date().timeIntervalSince1970)
        let sql = "UPDATE file_mapping_table SET owner_account = ?, update_time = ? WHERE id = ?;"

        var allSuccess = true
        for record in records {
            for attempt in 0..<3 {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (ownerAccount as NSString).utf8String, -1, nil)
                    sqlite3_bind_int64(stmt, 2, timestamp)
                    sqlite3_bind_int64(stmt, 3, record.id)

                    let result = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)

                    if result == SQLITE_DONE {
                        let changes = sqlite3_changes(db)
                        if changes > 0 {
                            dbLogger.info("✅ [DB] owner_account更新成功 | ID: \(record.id) | owner: \(ownerAccount, privacy: .public)")
                            break
                        }
                    }
                }
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.3)
                }
                if attempt == 2 {
                    allSuccess = false
                    dbLogger.error("❌ [DB] owner_account更新失败 | ID: \(record.id)")
                }
            }
        }
        return allSuccess
    }

    func updateAccessTime(ids: [Int64]) -> Bool {
        guard !ids.isEmpty else {
            return true
        }

        let timestamp = Int64(Date().timeIntervalSince1970)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "UPDATE file_mapping_table SET last_access_time = ? WHERE id IN (\(placeholders));"

        for attempt in 0..<3 {
            var stmt: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, timestamp)
                for (index, id) in ids.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(index + 2), id)
                }

                let result = sqlite3_step(stmt)
                sqlite3_finalize(stmt)

                if result == SQLITE_DONE {
                    let changes = sqlite3_changes(db)
                    if changes > 0 {
                        dbLogger.info("✅ [DB] 批量访问时间更新成功 | 更新记录数: \(changes)")
                        return true
                    }
                }
            }

            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        dbLogger.error("❌ [DB] 批量访问时间更新失败")
        return false
    }

    func updateAccessTime(uid: String) -> Bool {
        let records = queryRecordsByUID(uid: uid)
        if records.isEmpty {
            return false
        }
        let ids = records.map { $0.id }
        return updateAccessTime(ids: ids)
    }

    func updateVaultStatus(id: Int64, isLocalVault: Int) -> Bool {
        let sql = "UPDATE file_mapping_table SET is_local_vault = ?, update_time = ? WHERE id = ?;"
        let timestamp = Int64(Date().timeIntervalSince1970)

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(isLocalVault))
            sqlite3_bind_int64(stmt, 2, timestamp)
            sqlite3_bind_int64(stmt, 3, id)

            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if result == SQLITE_DONE {
                let changes = sqlite3_changes(db)
                if changes > 0 {
                    dbLogger.info("✅ [DB] Vault状态更新成功 | ID: \(id) | vault: \(isLocalVault)")
                    return true
                }
            }
        }

        dbLogger.error("❌ [DB] Vault状态更新失败 | ID: \(id)")
        return false
    }

    func updateVaultStatus(uid: String, isLocalVault: Int) -> Bool {
        let records = queryRecordsByUID(uid: uid)
        if records.isEmpty {
            return false
        }
        var success = true
        for record in records {
            if !updateVaultStatus(id: record.id, isLocalVault: isLocalVault) {
                success = false
            }
        }
        return success
    }

    func fetchAllLog() -> String {
        let sql = "SELECT id, uid, file_name, password, create_time, update_time, last_access_time, file_size, is_local_vault, owner_account FROM file_mapping_table ORDER BY last_access_time DESC;"
        var stmt: OpaquePointer?
        var result = ""

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                if let cUid = sqlite3_column_text(stmt, 1),
                   let cName = sqlite3_column_text(stmt, 2),
                   let cHash = sqlite3_column_text(stmt, 3) {
                    let uid = String(cString: cUid)
                    let name = String(cString: cName)
                    let hash = String(cString: cHash)
                    let createTime = sqlite3_column_int64(stmt, 4)
                    let updateTime = sqlite3_column_int64(stmt, 5)
                    let accessTime = sqlite3_column_int64(stmt, 6)
                    let fileSize = sqlite3_column_int64(stmt, 7)
                    let isLocal = sqlite3_column_int(stmt, 8)
                    let owner = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? ""

                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    let createDate = Date(timeIntervalSince1970: TimeInterval(createTime))
                    let updateDate = Date(timeIntervalSince1970: TimeInterval(updateTime))
                    let accessDate = Date(timeIntervalSince1970: TimeInterval(accessTime))
                    
                    let formattedCreateTime = dateFormatter.string(from: createDate)
                    let formattedUpdateTime = dateFormatter.string(from: updateDate)
                    let formattedAccessTime = dateFormatter.string(from: accessDate)

                    let isLocalStr = isLocal == 1 ? "已落盘" : "未落盘"

                    result += "📄 文件: \(name)\n"
                    result += "   ID: \(id)\n"
                    result += "   UID: \(uid)\n"
                    result += "   密码: \(hash)\n"
                    result += "   所属人: \(owner.isEmpty ? "(无)" : owner)\n"
                    result += "   创建时间: \(createTime) (\(formattedCreateTime))\n"
                    result += "   修改时间: \(updateTime) (\(formattedUpdateTime))\n"
                    result += "   访问时间: \(accessTime) (\(formattedAccessTime))\n"
                    result += "   大小: \(fileSize)\n"
                    result += "   状态: \(isLocalStr)\n\n"
                }
            }
        }
        sqlite3_finalize(stmt)
        return result.isEmpty ? "数据库当前为空" : result
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

    func queryRecordsByUID(uid: String) -> [FileMappingRecord] {
        let sql = "SELECT id, uid, file_name, password, create_time, update_time, last_access_time, file_size, is_local_vault, owner_account FROM file_mapping_table WHERE uid = ? ORDER BY is_local_vault DESC, last_access_time DESC;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (uid as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 1),
                   let cName = sqlite3_column_text(stmt, 2),
                   let cHash = sqlite3_column_text(stmt, 3) {
                    let owner = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? ""
                    records.append(FileMappingRecord(
                        id: sqlite3_column_int64(stmt, 0),
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password: String(cString: cHash),
                        create_time: sqlite3_column_int64(stmt, 4),
                        update_time: sqlite3_column_int64(stmt, 5),
                        last_access_time: sqlite3_column_int64(stmt, 6),
                        file_size: sqlite3_column_int64(stmt, 7),
                        is_local_vault: Int(sqlite3_column_int(stmt, 8)),
                        owner_account: owner
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)
        return records
    }

    func queryRecordByUID(uid: String) -> FileMappingRecord? {
        return queryRecordsByUID(uid: uid).first
    }

    func queryRecordsByFileName(fileName: String) -> [FileMappingRecord] {
        let normalizedName = normalizeFileName(fileName)

        let sql = "SELECT id, uid, file_name, password, create_time, update_time, last_access_time, file_size, is_local_vault, owner_account FROM file_mapping_table WHERE file_name LIKE ? ORDER BY last_access_time DESC;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let likePattern = "%" + normalizedName + "%"
            sqlite3_bind_text(stmt, 1, (likePattern as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 1),
                   let cName = sqlite3_column_text(stmt, 2),
                   let cHash = sqlite3_column_text(stmt, 3) {
                    let owner = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? ""
                    records.append(FileMappingRecord(
                        id: sqlite3_column_int64(stmt, 0),
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password: String(cString: cHash),
                        create_time: sqlite3_column_int64(stmt, 4),
                        update_time: sqlite3_column_int64(stmt, 5),
                        last_access_time: sqlite3_column_int64(stmt, 6),
                        file_size: sqlite3_column_int64(stmt, 7),
                        is_local_vault: Int(sqlite3_column_int(stmt, 8)),
                        owner_account: owner
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)
        return records
    }

    func queryTopActiveRecords(limit: Int) -> [FileMappingRecord] {
        let sql = "SELECT id, uid, file_name, password, create_time, update_time, last_access_time, file_size, is_local_vault, owner_account FROM file_mapping_table ORDER BY last_access_time DESC LIMIT ?;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 1),
                   let cName = sqlite3_column_text(stmt, 2),
                   let cHash = sqlite3_column_text(stmt, 3) {
                    let owner = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? ""
                    records.append(FileMappingRecord(
                        id: sqlite3_column_int64(stmt, 0),
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password: String(cString: cHash),
                        create_time: sqlite3_column_int64(stmt, 4),
                        update_time: sqlite3_column_int64(stmt, 5),
                        last_access_time: sqlite3_column_int64(stmt, 6),
                        file_size: sqlite3_column_int64(stmt, 7),
                        is_local_vault: Int(sqlite3_column_int(stmt, 8)),
                        owner_account: owner
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)
        return records
    }

    func queryAllLocalVaultRecords() -> [FileMappingRecord] {
        let sql = "SELECT id, uid, file_name, password, create_time, update_time, last_access_time, file_size, is_local_vault, owner_account FROM file_mapping_table WHERE is_local_vault = 1 ORDER BY last_access_time ASC;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 1),
                   let cName = sqlite3_column_text(stmt, 2),
                   let cHash = sqlite3_column_text(stmt, 3) {
                    let owner = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? ""
                    records.append(FileMappingRecord(
                        id: sqlite3_column_int64(stmt, 0),
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password: String(cString: cHash),
                        create_time: sqlite3_column_int64(stmt, 4),
                        update_time: sqlite3_column_int64(stmt, 5),
                        last_access_time: sqlite3_column_int64(stmt, 6),
                        file_size: sqlite3_column_int64(stmt, 7),
                        is_local_vault: Int(sqlite3_column_int(stmt, 8)),
                        owner_account: owner
                    ))
                }
            }
        }
        sqlite3_finalize(stmt)
        return records
    }
    
    func queryNonLocalVaultRecords() -> [FileMappingRecord] {
        let sql = "SELECT id, uid, file_name, password, create_time, update_time, last_access_time, file_size, is_local_vault, owner_account FROM file_mapping_table WHERE is_local_vault = 0 ORDER BY last_access_time ASC;"

        var stmt: OpaquePointer?
        var records: [FileMappingRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cUid = sqlite3_column_text(stmt, 1),
                   let cName = sqlite3_column_text(stmt, 2),
                   let cHash = sqlite3_column_text(stmt, 3) {
                    let owner = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) } ?? ""
                    records.append(FileMappingRecord(
                        id: sqlite3_column_int64(stmt, 0),
                        uid: String(cString: cUid),
                        file_name: String(cString: cName),
                        password: String(cString: cHash),
                        create_time: sqlite3_column_int64(stmt, 4),
                        update_time: sqlite3_column_int64(stmt, 5),
                        last_access_time: sqlite3_column_int64(stmt, 6),
                        file_size: sqlite3_column_int64(stmt, 7),
                        is_local_vault: Int(sqlite3_column_int(stmt, 8)),
                        owner_account: owner
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)
        return records
    }

    func deleteRecord(ids: [Int64]) -> Bool {
        guard !ids.isEmpty else {
            return true
        }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM file_mapping_table WHERE id IN (\(placeholders));"

        var success = false

        for attempt in 0..<3 {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (index, id) in ids.enumerated() {
                    sqlite3_bind_int64(stmt, Int32(index + 1), id)
                }

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
            dbLogger.info("✅ [DB] 批量记录删除成功 | 删除记录数: \(ids.count)")
        } else {
            dbLogger.error("❌ [DB] 批量记录删除失败")
        }

        return success
    }

    func deleteRecord(uid: String) -> Bool {
        let records = queryRecordsByUID(uid: uid)
        if records.isEmpty {
            return false
        }
        let ids = records.map { $0.id }
        return deleteRecord(ids: ids)
    }

    func deleteRecordByFileName(fileName: String) -> Bool {
        let normalizedName = normalizeFileName(fileName)
        let records = queryRecordsByFileName(fileName: normalizedName)
        if records.isEmpty {
            return false
        }
        let ids = records.map { $0.id }
        return deleteRecord(ids: ids)
    }
    
    func getConfigValue(key: String) -> String? {
        let sql = "SELECT value FROM global_config_table WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        var result: String?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    result = String(cString: cString)
                }
            }
        }

        sqlite3_finalize(stmt)
        return result
    }

    func setConfigValue(key: String, value: String) -> Bool {
        let sql = "INSERT INTO global_config_table (key, value, remark) VALUES (?, ?, '') ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, nil)

            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if result == SQLITE_DONE {
                dbLogger.info("✅ [DB] 配置写入成功 | key: \(key, privacy: .public)")
                return true
            }
        }

        dbLogger.error("❌ [DB] 配置写入失败 | key: \(key, privacy: .public)")
        return false
    }

    func setConfigValues(_ pairs: [String: String]) -> Bool {
        var allSuccess = true
        for (key, value) in pairs {
            if !setConfigValue(key: key, value: value) {
                allSuccess = false
            }
        }
        return allSuccess
    }

    func clearAllConfig() -> Bool {
        let sql = "DELETE FROM global_config_table;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let result = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if result == SQLITE_DONE {
                dbLogger.info("✅ [DB] 全局配置已清空")
                return true
            }
        }

        dbLogger.error("❌ [DB] 清空全局配置失败")
        return false
    }

    func fetchAllConfig() -> [GlobalConfigRecord] {
        let sql = "SELECT key, value, remark FROM global_config_table ORDER BY key;"
        var stmt: OpaquePointer?
        var records: [GlobalConfigRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
                let value = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
                let remark = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
                records.append(GlobalConfigRecord(key: key, value: value, remark: remark))
            }
        }
        sqlite3_finalize(stmt)
        return records
    }

    func fetchGlobalConfigLog() -> String {
        let records = fetchAllConfig()
        if records.isEmpty {
            return "全局配置表当前为空"
        }

        var result = ""
        for record in records {
            let label = record.remark.isEmpty ? record.key : record.remark
            let displayValue: String
            if record.value.isEmpty {
                displayValue = "(空)"
            } else if record.key == GlobalConfigKey.password {
                displayValue = "******"
            } else {
                displayValue = record.value
            }
            result += "\(label)：\(displayValue)\n"
        }
        return result
    }
}