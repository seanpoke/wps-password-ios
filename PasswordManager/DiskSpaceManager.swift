import Foundation
import OSLog
import Combine

class DiskSpaceManager: ObservableObject {
    static let shared = DiskSpaceManager()
    
    @Published private(set) var shouldShowWarning = false
    @Published private(set) var currentUsage: Int64 = 0
    @Published private(set) var threshold: Int64 = 1 * 1024 * 1024 * 1024 // 1GB 测试阈值
    
    private let appGroupID = "group.com.greenet.PasswordManager"
    private let safeVaultDir = "SafeVault"
    private var ignoredForever = false
    
    private init() {}
    
    func checkDiskSpace() async {
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
                DispatchQueue.main.async {
                    self.shouldShowWarning = false
                    self.currentUsage = 0
                }
                return
            }
            
            let totalSize = try calculateDirectorySize(at: vaultDir)
            
            DispatchQueue.main.async {
                self.currentUsage = totalSize
                if self.ignoredForever {
                    self.shouldShowWarning = false
                } else {
                    self.shouldShowWarning = totalSize > self.threshold
                }
            }
            
            if totalSize > threshold {
                let excessSize = totalSize - threshold
                appLogger.warning("⚠️ 磁盘空间超额: \(self.formatFileSize(excessSize))，需要提示用户清理")
            } else {
                appLogger.debug("📋 磁盘空间在安全范围内")
            }
            
        } catch {
            appLogger.error("❌ 检查磁盘空间失败: \(error)")
            DispatchQueue.main.async {
                self.shouldShowWarning = false
            }
        }
    }
    
    func dismissWarning(permanently: Bool = false) {
        shouldShowWarning = false
        if permanently {
            ignoredForever = true
            appLogger.info("🔕 用户选择永久忽略磁盘空间警告")
        }
    }
    
    private func calculateDirectorySize(at directoryURL: URL) throws -> Int64 {
        var totalSize: Int64 = 0
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )
        
        for fileURL in contents {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }
        
        return totalSize
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