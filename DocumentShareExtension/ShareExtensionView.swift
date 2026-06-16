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
    case passwordCapture
    case assetList
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
    @State private var capturedPassword: String = ""
    @State private var isVerifying: Bool = false
    @State private var verificationError: String?
    
    private let appGroupID = "group.com.sean.PasswordManager"
    private let tempInboxDir = "Temp_Inbox"
    
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
            case .passwordCapture:
                passwordCaptureView
                    .background(Color.orange)
            case .assetList:
                assetListView
                    .background(Color.gray)
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
                    
                    Text("密码: \(capturedPassword)")
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
    
    private var passwordCaptureView: some View {
        VStack(spacing: 40) {
            Spacer()
            
            Image(systemName: "key.fill")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text("验证文件密码")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("检测到加密文件: \(detectedFileName)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(12)
            }
            
            VStack(spacing: 16) {
                SecureField("请输入文件密码", text: $capturedPassword)
                    .font(.title)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(12)
                    .padding(.horizontal, 20)
                
                if let error = verificationError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }
            
            if isVerifying {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2)
            } else {
                Button(action: verifyAndRegisterAction) {
                    Text("验证并保存")
                        .font(.headline)
                        .foregroundColor(.orange)
                        .padding()
                        .frame(maxWidth: 280)
                        .background(Color.white)
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
    }
    
    private var assetListView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "folder.fill")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            Text("资产列表")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Spacer()
            
            Button(action: cancelAction) {
                Text("返回")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
            }
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
                        
                        await determineActionState(tempURL: tempURL, fileName: correctedName)
                        
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
    
    private func determineActionState(tempURL: URL, fileName: String) async {
        forceLog("🔍 [EXT] 开始确定动作状态")
        
        if let uid = ZipExtraFieldManager.shared.readUid(from: tempURL) {
            forceLog("✅ [EXT] 从文件尾部读出 UID: \(uid)")
            
            if AppGroupDBManager.shared.queryUID(forFileName: fileName) != nil {
                forceLog("✅ [EXT] UID 匹配数据库，进入同步确认状态")
                matchedAssetName = fileName
                actionState = .syncConfirm
            } else {
                forceLog("⚠️ [EXT] UID 存在但数据库无匹配，进入密码捕获状态")
                actionState = .passwordCapture
            }
        } else {
            forceLog("❌ [EXT] 未读出 UID，进入密码捕获状态")
            actionState = .passwordCapture
        }
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
    
    private func verifyAndRegisterAction() {
        guard !capturedPassword.isEmpty, let tempURL = tempFilePath else {
            verificationError = "请输入密码"
            return
        }
        
        isVerifying = true
        verificationError = nil
        
        OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
            Task { @MainActor in
                isVerifying = false
                
                switch result {
                case .success(let verified):
                    if verified {
                        registerNewFile(password: capturedPassword)
                    } else {
                        verificationError = "密码验证失败，请重试"
                    }
                case .failure(let error):
                    verificationError = error.localizedDescription
                }
            }
        }
    }
    
    private func registerNewFile(password: String) {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = formatFileName(originalName: detectedFileName, isNewFile: true)
        let uid = generateUID()
        
        forceLog("📝 [测试日志反馈] 开始登记新文件 | 文件名: \(fileName) | UID: \(uid)")
        
        Task.detached {
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: password)
            
            if success {
                let moveSuccess = await moveToDocumentsDirectory(tempURL: tempURL, newFileName: fileName)
                
                await MainActor.run {
                    if moveSuccess {
                        AppGroupDBManager.shared.upsertRecord(fileName: fileName, uid: uid)
                        forceLog("✅ [测试日志反馈] 新文件登记成功")
                        completeExtension()
                    } else {
                        completeExtension(withError: "文件迁移失败")
                    }
                }
            } else {
                await MainActor.run {
                    completeExtension(withError: "写入标记失败")
                }
            }
        }
    }
    
    private func syncOverrideAction() {
        guard let tempURL = tempFilePath, !detectedFileName.isEmpty else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = detectedFileName
        let uid = AppGroupDBManager.shared.queryUID(forFileName: fileName) ?? generateUID()
        
        forceLog("🔄 [测试日志反馈] 用户点击 [确定同步覆盖] | 目标文件: \(fileName) | UID: \(uid)")
        
        Task.detached {
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: nil)
            
            if success {
                let moveSuccess = await moveToDocumentsDirectory(tempURL: tempURL, newFileName: fileName)
                
                await MainActor.run {
                    if moveSuccess {
                        AppGroupDBManager.shared.upsertRecordWithSync(fileName: fileName, uid: uid)
                        forceLog("✅ [测试日志反馈] 同步覆盖成功")
                        completeExtension()
                    } else {
                        completeExtension(withError: "文件迁移失败")
                    }
                }
            } else {
                await MainActor.run {
                    completeExtension(withError: "写入标记失败")
                }
            }
        }
    }
    
    private func saveAsNewAction() {
        guard let tempURL = tempFilePath, !detectedFileName.isEmpty else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let newFileName = formatFileName(originalName: detectedFileName, isNewFile: false)
        let uid = generateUID()
        
        forceLog("➕ [测试日志反馈] 用户点击 [另存为新文件] | 新文件名: \(newFileName) | UID: \(uid)")
        
        Task.detached {
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: nil)
            
            if success {
                let moveSuccess = await moveToDocumentsDirectory(tempURL: tempURL, newFileName: newFileName)
                
                await MainActor.run {
                    if moveSuccess {
                        AppGroupDBManager.shared.upsertRecord(fileName: newFileName, uid: uid)
                        forceLog("✅ [测试日志反馈] 另存为新文件成功")
                        completeExtension()
                    } else {
                        completeExtension(withError: "文件迁移失败")
                    }
                }
            } else {
                await MainActor.run {
                    completeExtension(withError: "写入标记失败")
                }
            }
        }
    }
    
    private func formatFileName(originalName: String, isNewFile: Bool) -> String {
        let url = URL(fileURLWithPath: originalName)
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let baseName = url.deletingPathExtension().lastPathComponent
        
        if isNewFile {
            return "🔒[企业资产]_\(baseName)\(ext)"
        } else {
            let timestamp = String(Date().timeIntervalSince1970).prefix(10)
            return "🔒[企业资产]_\(baseName)_sync_\(timestamp)\(ext)"
        }
    }
    
    private func generateUID() -> String {
        return "LDAP_\(UUID().uuidString.prefix(8).uppercased())"
    }
    
    private func writeWppmMarkers(tempURL: URL, uid: String, password: String?) -> Bool {
        return ZipExtraFieldManager.shared.writeMetadata(
            to: tempURL,
            uid: uid,
            password: password,
            keyVersion: "default"
        )
    }
    
    private func moveToDocumentsDirectory(tempURL: URL, newFileName: String) async -> Bool {
        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            var destURL = documentsURL.appendingPathComponent(newFileName)
            
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            
            let coordinator = NSFileCoordinator()
            var error: NSError?
            
            coordinator.coordinate(writingItemAt: tempURL, options: .forMoving, error: &error) { newURL in
                do {
                    try FileManager.default.moveItem(at: newURL, to: destURL)
                    
                    var resourceValues = URLResourceValues()
                    resourceValues.isExcludedFromBackup = true
                    try destURL.setResourceValues(resourceValues)
                    
                    forceLog("✅ [测试日志反馈] 文件迁移成功: \(destURL.path)")
                } catch {
                    forceLog("❌ [测试日志反馈] 文件迁移失败: \(error)")
                }
            }
            
            if let error = error {
                forceLog("❌ [测试日志反馈] 文件协调失败: \(error)")
                return false
            }
            
            return FileManager.default.fileExists(atPath: destURL.path)
            
        } catch {
            forceLog("❌ [测试日志反馈] 文件迁移异常: \(error)")
            return false
        }
    }
    
    private func confirmViewAction() {
        if let password = ZipExtraFieldManager.shared.readPassword(from: tempFilePath!) {
            capturedPassword = password
        } else {
            capturedPassword = "SecLink#2026"
        }
        
        UIPasteboard.general.string = capturedPassword
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