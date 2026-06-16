import SwiftUI
import OSLog

let appLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "MainApp")

@main
struct PasswordManagerApp: App {
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhaseChange(phase)
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            appLogger.info("🔔 应用进入前台")
            Task {
                await performBackgroundCleanup()
            }
        case .background:
            appLogger.info("🔕 应用进入后台")
        case .inactive:
            break
        @unknown default:
            break
        }
    }
    
    private func performBackgroundCleanup() async {
        await cleanupExpiredTempFiles()
        await cleanupZombieIndexes()
        await cleanupLRUDiskSpace()
    }
    
    private func cleanupExpiredTempFiles() async {
        let appGroupID = "group.com.greenet.PasswordManager"
        let tempInboxDir = "Temp_Inbox"
        let expirationInterval: TimeInterval = 24 * 60 * 60
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            appLogger.error("❌ 无法获取 App Group 容器")
            return
        }
        
        let tempDir = containerURL.appendingPathComponent(tempInboxDir, isDirectory: true)
        
        do {
            if !FileManager.default.fileExists(atPath: tempDir.path) {
                appLogger.debug("📂 临时目录不存在")
                return
            }
            
            let contents = try FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
            
            let now = Date()
            var cleanedCount = 0
            
            for fileURL in contents {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                if let creationDate = attributes[.creationDate] as? Date {
                    let age = now.timeIntervalSince(creationDate)
                    
                    if age > expirationInterval {
                        try FileManager.default.removeItem(at: fileURL)
                        cleanedCount += 1
                        appLogger.info("🗑️ 清理过期临时文件: \(fileURL.lastPathComponent)")
                    }
                }
            }
            
            if cleanedCount > 0 {
                appLogger.info("✅ 临时文件清理完成，共移除 \(cleanedCount) 个过期文件")
            } else {
                appLogger.debug("📋 没有需要清理的过期临时文件")
            }
            
        } catch {
            appLogger.error("❌ 清理临时目录失败: \(error)")
        }
    }
    
    private func cleanupZombieIndexes() async {
        let appGroupID = "group.com.greenet.PasswordManager"
        let safeVaultDir = "SafeVault"
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            appLogger.error("❌ 无法获取 App Group 容器")
            return
        }
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        
        do {
            if !FileManager.default.fileExists(atPath: vaultDir.path) {
                appLogger.debug("📂 保险箱目录不存在")
                return
            }
            
            let localRecords = AppGroupDBManager.shared.queryAllLocalVaultRecords()
            appLogger.info("🔍 开始僵尸索引清洗，数据库中有 \(localRecords.count) 条本地记录")
            
            let vaultFiles = try FileManager.default.contentsOfDirectory(at: vaultDir, includingPropertiesForKeys: nil)
            let vaultFileNames = Set(vaultFiles.map { $0.lastPathComponent.lowercased() })
            
            var cleanedCount = 0
            
            for record in localRecords {
                let normalizedName = record.file_name.lowercased()
                
                if !vaultFileNames.contains(normalizedName) {
                    let success = AppGroupDBManager.shared.deleteRecord(uid: record.uid)
                    if success {
                        cleanedCount += 1
                        appLogger.info("🗑️ 清理僵尸索引: \(record.file_name) | UID: \(record.uid)")
                    }
                }
            }
            
            if cleanedCount > 0 {
                appLogger.info("✅ 僵尸索引清洗完成，共移除 \(cleanedCount) 条无效记录")
            } else {
                appLogger.debug("📋 没有僵尸索引需要清理")
            }
            
        } catch {
            appLogger.error("❌ 僵尸索引清洗失败: \(error)")
        }
    }
    
    private func cleanupLRUDiskSpace() async {
        let appGroupID = "group.com.greenet.PasswordManager"
        let safeVaultDir = "SafeVault"
        let maxDiskUsage: Int64 = 1 * 1024 * 1024 * 1024
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            appLogger.error("❌ 无法获取 App Group 容器")
            return
        }
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        
        do {
            if !FileManager.default.fileExists(atPath: vaultDir.path) {
                appLogger.debug("📂 保险箱目录不存在")
                return
            }
            
            let attributes = try FileManager.default.attributesOfItem(atPath: vaultDir.path)
            guard let totalSize = attributes[.size] as? Int64 else {
                appLogger.debug("📊 无法获取目录大小")
                return
            }
            
            appLogger.info("📊 保险箱当前占用: \(formatFileSize(totalSize)) | 阈值: \(formatFileSize(maxDiskUsage))")
            
            if totalSize <= maxDiskUsage {
                appLogger.debug("📋 磁盘空间在安全范围内")
                return
            }
            
            let excessSize = totalSize - maxDiskUsage
            appLogger.warning("⚠️ 磁盘空间超额: \(formatFileSize(excessSize))，需要清理")
            
            let localRecords = AppGroupDBManager.shared.queryAllLocalVaultRecords()
            
            var freedSize: Int64 = 0
            var cleanedCount = 0
            
            for record in localRecords {
                guard freedSize < excessSize else {
                    break
                }
                
                let fileURL = vaultDir.appendingPathComponent(record.file_name)
                
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                        let fileSize = fileAttributes[.size] as? Int64 ?? 0
                        
                        try FileManager.default.removeItem(at: fileURL)
                        AppGroupDBManager.shared.deleteRecord(uid: record.uid)
                        
                        freedSize += fileSize
                        cleanedCount += 1
                        
                        appLogger.info("🗑️ LRU清理: \(record.file_name) | 大小: \(formatFileSize(fileSize))")
                    } catch {
                        appLogger.error("❌ LRU清理失败: \(record.file_name) | \(error)")
                    }
                }
            }
            
            appLogger.info("✅ LRU清理完成，共移除 \(cleanedCount) 个文件，释放 \(formatFileSize(freedSize))")
            
        } catch {
            appLogger.error("❌ LRU磁盘清理失败: \(error)")
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        appLogger.info("🚀 应用启动")
        
        Task {
            await performLaunchCleanup()
        }
        
        return true
    }
    
    private func performLaunchCleanup() async {
        let appGroupID = "group.com.greenet.PasswordManager"
        let tempInboxDir = "Temp_Inbox"
        let expirationInterval: TimeInterval = 24 * 60 * 60
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            appLogger.error("❌ 无法获取 App Group 容器")
            return
        }
        
        let tempDir = containerURL.appendingPathComponent(tempInboxDir, isDirectory: true)
        
        do {
            if !FileManager.default.fileExists(atPath: tempDir.path) {
                appLogger.debug("📂 临时目录不存在")
                return
            }
            
            let contents = try FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )
            
            let now = Date()
            var cleanedCount = 0
            
            for fileURL in contents {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                if let creationDate = attributes[.creationDate] as? Date {
                    let age = now.timeIntervalSince(creationDate)
                    
                    if age > expirationInterval {
                        try FileManager.default.removeItem(at: fileURL)
                        cleanedCount += 1
                        appLogger.info("🗑️ 启动时清理过期临时文件: \(fileURL.lastPathComponent)")
                    }
                }
            }
            
            if cleanedCount > 0 {
                appLogger.info("✅ 启动清理完成，共移除 \(cleanedCount) 个过期文件")
            } else {
                appLogger.debug("📋 启动时没有需要清理的过期文件")
            }
            
        } catch {
            appLogger.error("❌ 启动时清理临时目录失败: \(error)")
        }
    }
}