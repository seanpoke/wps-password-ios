import SwiftUI
import UniformTypeIdentifiers

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
                Button(action: syncOverrideAction) {
                    Text("确定同步覆盖")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .padding()
                        .frame(maxWidth: 280)
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(radius: 8)
                }
                
                Button(action: saveAsNewAction) {
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
    }
    
    private func processIncomingFiles() async {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return
        }
        
        for item in inputItems {
            guard let attachments = item.attachments else { continue }
            
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    do {
                        let url = try await attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as! URL
                        let tempURL = try copyToTempInbox(sourceURL: url)
                        tempFilePath = tempURL
                        
                        let correctedName = try detectAndCorrectFileExtension(fileURL: tempURL)
                        detectedFileName = correctedName
                        
                        if checkAssetMatch(fileName: correctedName) {
                            matchedAssetName = correctedName
                            actionState = .syncConfirm
                        }
                    } catch {
                        print("❌ 文件处理失败: \(error)")
                    }
                }
            }
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
    
    private func checkAssetMatch(fileName: String) -> Bool {
        let normalizedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let _ = AppGroupDBManager.shared.queryUID(forFileName: normalizedName) {
            return true
        }
        return false
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
        let normalizedName = detectedFileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let success = AppGroupDBManager.shared.upsertRecord(fileName: normalizedName, uid: "LDAP_SEAN_999")
        
        if success {
            print("✅ 资产同步成功")
        }
        onDismiss()
    }
    
    private func saveAsNewAction() {
        let url = URL(fileURLWithPath: detectedFileName)
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let baseName = url.deletingPathExtension().lastPathComponent
        let newName = "\(baseName)_copy\(ext)"
        
        AppGroupDBManager.shared.saveFileMapping(fileName: newName, ldapUID: "LDAP_SEAN_999", passwordMock: mockPassword)
        onDismiss()
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
                print("❌ 清理临时目录失败: \(error)")
            }
        }
    }
}