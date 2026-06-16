import SwiftUI
import OSLog

let appLogger = Logger(subsystem: "com.sean.PasswordManager", category: "MainApp")

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
                await cleanupExpiredTempFiles()
            }
        case .background:
            appLogger.info("🔕 应用进入后台")
        case .inactive:
            break
        @unknown default:
            break
        }
    }
    
    private func cleanupExpiredTempFiles() async {
        let appGroupID = "group.com.sean.PasswordManager"
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
                appLogger.info("✅ 清理完成，共移除 \(cleanedCount) 个过期文件")
            } else {
                appLogger.debug("📋 没有需要清理的过期文件")
            }
            
        } catch {
            appLogger.error("❌ 清理临时目录失败: \(error)")
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        appLogger.info("🚀 应用启动")
        
        Task {
            await cleanupExpiredTempFilesOnLaunch()
        }
        
        return true
    }
    
    private func cleanupExpiredTempFilesOnLaunch() async {
        let appGroupID = "group.com.sean.PasswordManager"
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