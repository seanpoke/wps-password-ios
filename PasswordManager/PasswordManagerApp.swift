import SwiftUI
import OSLog

let appLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "MainApp")

@main
struct PasswordManagerApp: App {
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var showLogin = false
    @State private var isCheckingToken = true
    
    var body: some Scene {
        WindowGroup {
            if isCheckingToken {
                ProgressView("正在验证...")
                    .onAppear {
                        checkTokenAndNavigate()
                    }
            } else if showLogin {
                LoginView(onLoginSuccess: {
                    showLogin = false
                    isCheckingToken = false
                })
            } else {
                ContentView(onLogout: {
                    performLogout()
                })
            }
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhaseChange(phase)
        }
    }
    
    private func checkTokenAndNavigate() {
        appLogger.info("🔍 [App] 开始验证token")
        
        APIService.shared.bootstrap { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let bootstrapResult):
                    if bootstrapResult.isAuthenticated {
                        appLogger.info("✅ [App] Token校验成功，进入主界面")
                        isCheckingToken = false
                        showLogin = false
                    } else {
                        appLogger.info("🔑 [App] 未认证，跳转到登录页面")
                        isCheckingToken = false
                        showLogin = true
                    }
                case .failure:
                    appLogger.info("🔑 [App] 认证失败，跳转到登录页面")
                    isCheckingToken = false
                    showLogin = true
                }
            }
        }
    }
    
    private func performLogout() {
        APIService.shared.logout { result in
            switch result {
            case .success:
                appLogger.info("✅ [App] 注销完成，跳转到登录页面")
            case .failure(let error):
                appLogger.error("❌ [App] 远程登出失败，本地token已清空: \(error.localizedDescription)")
            }

            self.isCheckingToken = false
            self.showLogin = true
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
        await cleanupExpiredNonLocalVaultRecords()
        await checkVaultDiskSpace()
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
    
    private func cleanupExpiredNonLocalVaultRecords() async {
        let expirationInterval: TimeInterval = 24 * 60 * 60
        
        let nonLocalRecords = AppGroupDBManager.shared.queryNonLocalVaultRecords()
        appLogger.info("🔍 开始未落盘记录清理，数据库中有 \(nonLocalRecords.count) 条未落盘记录")
        
        let now = Date().timeIntervalSince1970
        var cleanedCount = 0
        
        for record in nonLocalRecords {
            let age = now - TimeInterval(record.last_access_time)
            
            if age > expirationInterval {
                let success = AppGroupDBManager.shared.deleteRecord(uid: record.uid)
                if success {
                    cleanedCount += 1
                    appLogger.info("🗑️ 清理过期未落盘记录: \(record.file_name) | UID: \(record.uid)")
                }
            }
        }
        
        if cleanedCount > 0 {
            appLogger.info("✅ 未落盘记录清理完成，共移除 \(cleanedCount) 条过期记录")
        } else {
            appLogger.debug("📋 没有过期的未落盘记录需要清理")
        }
    }
    
    private func checkVaultDiskSpace() async {
        await DiskSpaceManager.shared.checkDiskSpace()
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