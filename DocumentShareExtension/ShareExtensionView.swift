import SwiftUI
import UniformTypeIdentifiers
import Foundation
import OSLog

let shareExtensionLogger = Logger(subsystem: "com.sean.PasswordManager", category: "ShareExtension")

func forceLog(_ message: String) {
    shareExtensionLogger.info("\(message, privacy: .public)")
}

@MainActor
enum ActionState {
    case identifying
    case syncConfirm
}

struct ShareExtensionView: View {
    
    private let extensionContext: NSExtensionContext?
    private let onDismiss: () -> Void
    private let onOpenIn: (URL) -> Void
    
    @State private var actionState: ActionState = .identifying
    @State private var detectedFileName: String = ""
    @State private var countdownSeconds: Int = 0
    @State private var isCountingDown: Bool = false
    @State private var tempFilePath: URL?
    @State private var matchedAssetName: String = ""
    
    private let appGroupID = "group.com.sean.PasswordManager"
    private let tempInboxDir = "Temp_Inbox"
    private let mockPassword = "SecLink#2026"
    
    init(extensionContext: NSExtensionContext?, onDismiss: @escaping () -> Void, onOpenIn: @escaping (URL) -> Void) {
        self.extensionContext = extensionContext
        self.onDismiss = onDismiss
        self.onOpenIn = onOpenIn
        forceLog("✅ [EXT] ShareExtensionView init | extensionContext: \(extensionContext != nil ? "有效" : "nil")")
    }
    
    var body: some View {
        ZStack {
            switch actionState {
            case .identifying:
                identifyingView
                    .background(Color.green)
            case .syncConfirm:
                syncConfirmView
                    .background(Color.blue)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            Task {
                await processIncomingFiles()
            }
        }
        .onDisappear {
            cleanupTempDirectory()
        }
    }
    
    private var identifyingView: some View {
        VStack(spacing: 40) {
            Spacer()
            
            Image(systemName: "lock.open")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text("文件识别完成")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("检测到: \(detectedFileName)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(12)
            }
            
            if isCountingDown {
                VStack(spacing: 8) {
                    Text("密码已复制到剪贴板")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    
                    Text("密码: \(mockPassword)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                    
                    Text("剩余 \(countdownSeconds) 秒")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
            }
            
            Button(action: confirmViewAction) {
                Text("确认查看")
                    .font(.headline)
                    .foregroundColor(.green)
                    .padding()
                    .frame(maxWidth: 280)
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(radius: 8)
            }
            
            Button(action: cancelAction) {
                Text("取消")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            Spacer()
        }
    }
    
    private var syncConfirmView: some View {
        VStack(spacing: 40) {
            Spacer()
            
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text("检测到回流资产")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("匹配到: \(matchedAssetName)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(12)
            }
            
            VStack(spacing: 16) {
                Button(action: {
                    forceLog("===== [SYNC OVERRIDE BUTTON CLICKED] =====")
                    forceLog("⏰ 按钮点击时间: \(Date())")
                    forceLog("📋 matchedAssetName: \(matchedAssetName)")
                    forceLog("📋 detectedFileName: \(detectedFileName)")
                    forceLog("📋 tempFilePath: \(tempFilePath?.path ?? "nil")")
                    forceLog("==========================================")
                    syncOverrideAction()
                }) {
                    Text("确定同步覆盖")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .padding()
                        .frame(maxWidth: 280)
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(radius: 8)
                }
                
                Button(action: {
                    forceLog("===== [SAVE AS NEW BUTTON CLICKED] =====")
                    forceLog("⏰ 按钮点击时间: \(Date())")
                    saveAsNewAction()
                }) {
                    Text("另存为新文件")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: 280)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(16)
                        .shadow(radius: 8)
                }
            }
            
            Button(action: cancelAction) {
                Text("取消")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            Spacer()
        }
        .onAppear {
            forceLog("===== [syncConfirmView 显示] =====")
            forceLog("📊 matchedAssetName: \(matchedAssetName)")
            forceLog("📊 detectedFileName: \(detectedFileName)")
            forceLog("📊 tempFilePath: \(tempFilePath?.path ?? "nil")")
            forceLog("==================================")
        }
    }
    
    private func processIncomingFiles() async {
        forceLog("🔄 [EXT] processIncomingFiles 开始")
        
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            forceLog("❌ [EXT] inputItems 为空")
            return
        }
        
        forceLog("📦 [EXT] 输入项数量: \(inputItems.count)")
        
        for (index, item) in inputItems.enumerated() {
            guard let attachments = item.attachments else { 
                forceLog("⚠️ [EXT] 第\(index)项没有附件")
                continue 
            }
            
            forceLog("📎 [EXT] 第\(index)项附件数量: \(attachments.count)")
            
            for (attachIndex, attachment) in attachments.enumerated() {
                forceLog("🔍 [EXT] 检查附件 \(attachIndex): \(attachment)")
                
                if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    forceLog("✅ [EXT] 附件 \(attachIndex) 符合 fileURL 类型")
                    
                    do {
                        forceLog("📥 [EXT] 开始加载附件 \(attachIndex)")
                        let loadedItem = try await attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                        
                        guard let url = loadedItem as? URL else {
                            forceLog("❌ [EXT] 加载的项不是 URL: \(type(of: loadedItem))")
                            continue
                        }
                        
                        forceLog("📄 [EXT] 加载到 URL: \(url.path)")
                        
                        let tempURL = try copyToTempInbox(sourceURL: url)
                        tempFilePath = tempURL
                        
                        forceLog("📁 [EXT] 临时文件路径: \(tempURL.path)")
                        
                        let correctedName = try detectAndCorrectFileExtension(fileURL: tempURL)
                        detectedFileName = correctedName
                        
                        forceLog("📝 [EXT] 检测到文件名: \(correctedName)")
                        
                        if checkAssetMatch(fileName: correctedName) {
                            matchedAssetName = correctedName
                            actionState = .syncConfirm
                            forceLog("🔄 [EXT] 状态切换到 syncConfirm")
                        }
                    } catch {
                        forceLog("❌ [EXT] 文件处理失败: \(error)")
                    }
                } else {
                    forceLog("⚠️ [EXT] 附件 \(attachIndex) 不符合 fileURL 类型")
                }
            }
        }
        
        forceLog("✅ [EXT] processIncomingFiles 完成")
    }
    
    private func copyToTempInbox(sourceURL: URL) throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw NSError(domain: "ShareExtension", code: -1, userInfo: [NSLocalizedDescriptionKey: "App Group 容器获取失败"])
        }
        
        let tempDir = containerURL.appendingPathComponent(tempInboxDir, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let fileName = sourceURL.lastPathComponent
        let destURL = tempDir.appendingPathComponent(fileName)
        
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }
    
    private func detectAndCorrectFileExtension(fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }
        
        let magicBytes = try fileHandle.read(upToCount: 4) ?? Data()
        
        if magicBytes.count >= 4 {
            let magicNumber = magicBytes.map { String(format: "%02X", $0) }.joined()
            if magicNumber == "504B0304" {
                let centralDirSignature = Data([0x50, 0x4B, 0x01, 0x02])
                
                try fileHandle.seek(toOffset: 0)
                let fileData = try fileHandle.readToEnd() ?? Data()
                
                if let centralDirRange = fileData.range(of: centralDirSignature) {
                    let startOffset = centralDirRange.upperBound
                    let searchRange = startOffset..<min(startOffset + 1024, fileData.count)
                    let searchData = fileData.subdata(in: searchRange)
                    let searchString = String(data: searchData, encoding: .utf8) ?? ""
                    
                    if searchString.contains("word/") {
                        return correctExtension(fileURL: fileURL, targetExt: ".docx")
                    } else if searchString.contains("xl/") {
                        return correctExtension(fileURL: fileURL, targetExt: ".xlsx")
                    } else if searchString.contains("ppt/") {
                        return correctExtension(fileURL: fileURL, targetExt: ".pptx")
                    }
                }
            }
        }
        
        return fileURL.lastPathComponent
    }
    
    private func correctExtension(fileURL: URL, targetExt: String) -> String {
        let fileName = fileURL.lastPathComponent
        let lowerName = fileName.lowercased()
        
        if lowerName.hasSuffix(".zip") {
            return fileName.replacingOccurrences(of: ".zip", with: targetExt, options: .caseInsensitive)
        } else if lowerName.hasSuffix(".docx") || lowerName.hasSuffix(".xlsx") || lowerName.hasSuffix(".pptx") {
            return fileName
        } else if !fileName.contains(".") {
            return fileName + targetExt
        } else {
            let components = fileName.components(separatedBy: ".")
            if components.count > 1 {
                let baseName = components.dropLast().joined(separator: ".")
                return baseName + targetExt
            }
            return fileName + targetExt
        }
    }
    
    private func checkAssetMatch(fileName: String) -> Bool {
        let normalizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        forceLog("🔍 [EXT] 检查资产匹配: \(normalizedName)")
        
        if let uid = AppGroupDBManager.shared.queryUID(forFileName: normalizedName) {
            forceLog("✅ [EXT] 找到匹配的资产 | UID: \(uid)")
            return true
        } else {
            forceLog("❌ [EXT] 未找到匹配的资产")
            return false
        }
    }
    
    private func confirmViewAction() {
        UIPasteboard.general.string = mockPassword
        isCountingDown = true
        countdownSeconds = 60
        
        Task {
            while countdownSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdownSeconds -= 1
            }
            UIPasteboard.general.string = nil
            isCountingDown = false
            
            if let url = tempFilePath {
                onOpenIn(url)
            } else {
                onDismiss()
            }
        }
    }
    
    private func syncOverrideAction() {
        forceLog("🔄 [DEBUG] syncOverrideAction 开始执行")
        
        guard let tempURL = tempFilePath, !detectedFileName.isEmpty else {
            forceLog("❌ [DEBUG] 文件路径无效")
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = detectedFileName
        let groupID = appGroupID
        
        forceLog("🔄 [测试日志反馈] 用户点击 [确定同步覆盖] | 目标文件: \(fileName)")
        forceLog("📂 [测试日志反馈] 源文件路径: \(tempURL.path)")
        forceLog("🔧 [DEBUG] 即将启动后台任务")
        
        Task.detached {
            forceLog("🔧 [DEBUG] 后台任务已启动")
            let startTime = Date()
            let deadline = Date().addingTimeInterval(5)
            
            let task = Task { () -> Bool in
                while Date() < deadline {
                    guard !Task.isCancelled else {
                        forceLog("⏹️ [测试日志反馈] 任务已取消")
                        return false
                    }
                    
                    let targetPath = Self.getSharedDocumentsPath(fileName: fileName, appGroupID: groupID)
                    
                    guard let targetURL = targetPath else {
                        forceLog("❌ [测试日志反馈] 无法获取目标路径")
                        return false
                    }
                    
                    forceLog("📤 [测试日志反馈] 目标文件路径: \(targetURL.path)")
                    
                    do {
                        let sourceSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64 ?? 0
                        forceLog("📊 [测试日志反馈] 源文件大小: \(sourceSize) bytes")
                        
                        try Self.copyFileChunked(sourceURL: tempURL, targetURL: targetURL)
                        forceLog("📥 [测试日志反馈] 文件分块复制完成")
                        
                        let targetSize = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int64 ?? 0
                        forceLog("📊 [测试日志反馈] 目标文件大小: \(targetSize) bytes")
                        
                        if sourceSize == targetSize {
                            forceLog("✅ [测试日志反馈] 文件大小校验通过")
                        } else {
                            forceLog("⚠️ [测试日志反馈] 文件大小不一致! 源: \(sourceSize), 目标: \(targetSize)")
                        }
                        
                        let normalizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let success = AppGroupDBManager.shared.upsertRecordWithSync(fileName: normalizedName, uid: "LDAP_SEAN_999")
                        
                        if success {
                            let accessTime = AppGroupDBManager.shared.queryLastAccessTime(forFileName: fileName)
                            let syncTime = AppGroupDBManager.shared.queryLastSyncTime(forFileName: fileName)
                            forceLog("🕐 [测试日志反馈] last_access_time: \(accessTime ?? "N/A")")
                            forceLog("🔄 [测试日志反馈] last_sync_time: \(syncTime ?? "N/A")")
                        }
                        
                        return success
                    } catch {
                        forceLog("❌ [测试日志反馈] 文件覆盖失败: \(error)")
                        return false
                    }
                }
                forceLog("⏱️ [测试日志反馈] 处理超时 (5秒)")
                return false
            }
            
            let result = await task.value
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            
            forceLog("🔧 [DEBUG] 后台任务完成，结果: \(result)，耗时: \(elapsed)ms")
            
            await MainActor.run { [self] in
                forceLog("🔧 [DEBUG] 回到主队列")
                if result {
                    forceLog("✅ [测试日志反馈] 资产同步覆盖成功 | 耗时: \(String(format: "%.2f", elapsed))ms")
                    completeExtension()
                } else {
                    forceLog("❌ [测试日志反馈] 资产同步覆盖失败 | 耗时: \(String(format: "%.2f", elapsed))ms")
                    completeExtension(withError: "处理超时，请重试")
                }
            }
        }
        
        forceLog("🔧 [DEBUG] syncOverrideAction 方法返回")
    }
    
    private func saveAsNewAction() {
        guard let tempURL = tempFilePath, !detectedFileName.isEmpty else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = detectedFileName
        let groupID = appGroupID
        
        forceLog("➕ [测试日志反馈] 用户点击 [另存为新文件] | 原文件: \(fileName)")
        
        Task.detached {
            let startTime = Date()
            let deadline = Date().addingTimeInterval(5)
            
            let task = Task { () -> Bool in
                while Date() < deadline {
                    guard !Task.isCancelled else {
                        forceLog("⏹️ [测试日志反馈] 任务已取消")
                        return false
                    }
                    
                    let url = URL(fileURLWithPath: fileName)
                    let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
                    let baseName = url.deletingPathExtension().lastPathComponent
                    let timestamp = String(Date().timeIntervalSince1970).prefix(10)
                    let newName = "\(baseName)_sync_\(timestamp)\(ext)"
                    
                    forceLog("📝 [测试日志反馈] 新文件名: \(newName)")
                    
                    let targetPath = Self.getSharedDocumentsPath(fileName: newName, appGroupID: groupID)
                    
                    guard let targetURL = targetPath else {
                        forceLog("❌ [测试日志反馈] 无法获取目标路径")
                        return false
                    }
                    
                    do {
                        let sourceSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64 ?? 0
                        forceLog("📊 [测试日志反馈] 源文件大小: \(sourceSize) bytes")
                        
                        try Self.copyFileChunked(sourceURL: tempURL, targetURL: targetURL)
                        forceLog("📥 [测试日志反馈] 文件分块复制完成")
                        
                        let targetSize = try FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int64 ?? 0
                        forceLog("📊 [测试日志反馈] 新文件大小: \(targetSize) bytes")
                        
                        let normalizedName = newName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let success = AppGroupDBManager.shared.upsertRecord(fileName: normalizedName, uid: "LDAP_SEAN_999")
                        
                        if success {
                            let accessTime = AppGroupDBManager.shared.queryLastAccessTime(forFileName: newName)
                            forceLog("🕐 [测试日志反馈] last_access_time: \(accessTime ?? "N/A")")
                        }
                        
                        return success
                    } catch {
                        forceLog("❌ [测试日志反馈] 文件另存失败: \(error)")
                        return false
                    }
                }
                forceLog("⏱️ [测试日志反馈] 处理超时 (5秒)")
                return false
            }
            
            let result = await task.value
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            
            await MainActor.run { [self] in
                if result {
                    forceLog("✅ [测试日志反馈] 新文件保存成功 | 耗时: \(String(format: "%.2f", elapsed))ms")
                    completeExtension()
                } else {
                    forceLog("❌ [测试日志反馈] 新文件保存失败 | 耗时: \(String(format: "%.2f", elapsed))ms")
                    completeExtension(withError: "处理超时，请重试")
                }
            }
        }
    }
    
    nonisolated private static func copyFileChunked(sourceURL: URL, targetURL: URL) throws {
        let bufferSize = 8 * 1024 * 1024
        
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        
        let inputHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { inputHandle.closeFile() }
        
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: targetURL)
        defer { outputHandle.closeFile() }
        
        var bytesRead = 0
        
        repeat {
            try Task.checkCancellation()
            
            autoreleasepool {
                do {
                    let data = try inputHandle.read(upToCount: bufferSize)
                    
                    if let data = data, !data.isEmpty {
                        try outputHandle.write(contentsOf: data)
                        bytesRead = data.count
                    } else {
                        bytesRead = 0
                    }
                } catch {
                    bytesRead = 0
                }
            }
            
        } while bytesRead > 0
    }
    
    nonisolated private static func getSharedDocumentsPath(fileName: String, appGroupID: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        
        let documentsDir = containerURL.appendingPathComponent("Documents", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        } catch {
            shareExtensionLogger.error("❌ 创建目录失败: \(error, privacy: .public)")
            return nil
        }
        
        return documentsDir.appendingPathComponent(fileName)
    }
    
    private func completeExtension(withError errorMessage: String? = nil) {
        if let error = errorMessage {
            forceLog("❌ [扩展退出] 错误: \(error)")
        }
        
        forceLog("👋 [扩展退出] 即将调用 completeRequest")
        
        extensionContext?.completeRequest(returningItems: [], completionHandler: { _ in
            forceLog("✅ [扩展退出] completeRequest 调用完成")
            self.cleanupTempDirectory()
            self.onDismiss()
        })
    }
    
    private func cancelAction() {
        cleanupTempDirectory()
        onDismiss()
    }
    
    private func cleanupTempDirectory() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        
        let tempDir = containerURL.appendingPathComponent(tempInboxDir, isDirectory: true)
        
        Task {
            do {
                if FileManager.default.fileExists(atPath: tempDir.path) {
                    let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                    for file in contents {
                        try FileManager.default.removeItem(at: file)
                    }
                }
            } catch {
                shareExtensionLogger.error("❌ 清理临时目录失败: \(error, privacy: .public)")
            }
        }
    }
}