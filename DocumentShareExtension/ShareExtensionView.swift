import SwiftUI
import UniformTypeIdentifiers
import Foundation
import OSLog

let shareExtensionLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "ShareExtension")

@MainActor
enum ActionState: CustomStringConvertible {
    case identifying
    case greenCanvas
    case yellowCanvas
    case blueCanvasA
    case blueCanvasB
    case stateD
    
    var description: String {
        switch self {
        case .identifying: return "identifying"
        case .greenCanvas: return "greenCanvas"
        case .yellowCanvas: return "yellowCanvas"
        case .blueCanvasA: return "blueCanvasA"
        case .blueCanvasB: return "blueCanvasB"
        case .stateD: return "stateD"
        }
    }
}

@MainActor
enum HostType {
    case wps
    case external
    case unknown
}

struct ShareExtensionView: View {
    
    private let extensionContext: NSExtensionContext?
    private let onDismiss: () -> Void
    private let onOpenIn: (URL) -> Void
    
    @State private var actionState: ActionState = .identifying
    @State private var hostType: HostType = .unknown
    @State private var detectedFileName: String = ""
    @State private var tempFilePath: URL?
    @State private var originalSourceURL: URL?
    @State private var matchedAssetName: String = ""
    @State private var matchedUID: String = ""
    @State private var capturedPassword: String = ""
    @State private var isVerifying: Bool = false
    @State private var verificationError: String?
    @State private var fileSize: Int64 = 0
    @State private var isBruteForcing: Bool = false
    @State private var hasPasswordInMetadata: Bool = false
    
    @State private var assetList: [FileMappingRecord] = []
    @State private var showAssetList: Bool = false
    
    private let appGroupID = "group.com.greenet.PasswordManager"
    private let tempInboxDir = "Temp_Inbox"
    private let safeVaultDir = "SafeVault"
    
    init(extensionContext: NSExtensionContext?, onDismiss: @escaping () -> Void, onOpenIn: @escaping (URL) -> Void) {
        self.extensionContext = extensionContext
        self.onDismiss = onDismiss
        self.onOpenIn = onOpenIn
        shareExtensionLogger.info("✅ [EXT] ===== ShareExtensionView 初始化 ===== ")
        shareExtensionLogger.info("✅ [EXT] extensionContext: \(extensionContext != nil ? "有效" : "nil")")
    }
    
    var body: some View {
        ZStack {
            switch actionState {
            case .identifying:
                identifyingView
                    .background(Color.gray)
            case .greenCanvas:
                greenCanvasView
                    .background(Color.green)
            case .yellowCanvas:
                yellowCanvasView
                    .background(Color.orange)
            case .blueCanvasA:
                blueCanvasSubAView
                    .background(Color.blue)
            case .blueCanvasB:
                blueCanvasSubBView
                    .background(Color.blue)
            case .stateD:
                stateDView
                    .background(Color.gray)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            shareExtensionLogger.info("✅ [EXT] ===== View onAppear 触发 ===== ")
            Task {
                shareExtensionLogger.info("✅ [EXT] 开始执行 processIncomingFiles")
                await processIncomingFiles()
                shareExtensionLogger.info("✅ [EXT] processIncomingFiles 执行完毕，当前状态: \(actionState)")
            }
        }
        .onChange(of: actionState) { newState in
            shareExtensionLogger.info("🔄 [EXT] actionState 变更: \(newState)")
        }
        .onDisappear {
            shareExtensionLogger.info("✅ [EXT] ===== View onDisappear 触发 ===== ")
            cleanupTempDirectory()
        }
    }
    
    private var identifyingView: some View {
        VStack(spacing: 40) {
            Spacer()
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(2)
            
            Text("正在识别文件...")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("检测到: \(detectedFileName)")
                .font(.headline)
                .foregroundColor(.white.opacity(0.9))
            
            Spacer()
        }
    }
    
    private var greenCanvasView: some View {
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
            
            if hasPasswordInMetadata {
                Text("密码: \(capturedPassword)")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
            }
            
            Button(action: copyPasswordAndExit) {
                Text(hasPasswordInMetadata ? "复制密码并退场" : "当前文档无密码")
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
    
    private var yellowCanvasView: some View {
        VStack(spacing: 40) {
            Spacer()
            
            Image(systemName: "key.fill")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text("登记新文件")
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
                VStack(spacing: 16) {
                    Button(action: verifyAndRegisterAsNew) {
                        Text("登记为本地新文件")
                            .font(.headline)
                            .foregroundColor(.orange)
                            .padding()
                            .frame(maxWidth: 280)
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
                    
                    Button(action: showAssetSelection) {
                        Text("关联并覆盖本地已有文件")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: 280)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
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
    
    private var blueCanvasSubAView: some View {
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
                
                Button(action: showAssetSelection) {
                    Text("选择其他文件关联覆盖")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: 280)
                        .background(Color.white.opacity(0.15))
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
    
    private var blueCanvasSubBView: some View {
        VStack(spacing: 40) {
            Spacer()
            
            Image(systemName: "lock.fill")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text(matchedUID.isEmpty ? "密码撞击失败" : "需要验证身份")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(matchedUID.isEmpty ? "检测到: \(detectedFileName)" : "检测到身份标识: \(detectedFileName)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(12)
                
                if !matchedUID.isEmpty {
                    Text("文件携带身份标识，正在验证...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            VStack(spacing: 16) {
                SecureField(matchedUID.isEmpty ? "请输入最新密码" : "请输入文件密码", text: $capturedPassword)
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
                VStack(spacing: 16) {
                    Button(action: overrideWithNewPassword) {
                        Text(matchedUID.isEmpty ? "确定同步覆盖(同名老资产)" : "确认登记并保留身份")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .padding()
                            .frame(maxWidth: 280)
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
                    
                    Button(action: verifyAndRegisterAsNew) {
                        Text("登记为本地新文件")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: 280)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
                    
                    Button(action: showAssetSelection) {
                        Text("关联并覆盖本地已有文件")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: 280)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
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
    
    private var stateDView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "folder.fill")
                .font(.system(size: 60))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            Text("选择要覆盖的资产")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Spacer()
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(assetList, id: \.uid) { record in
                        Button(action: { selectAsset(record: record) }) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.file_name)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text("UID: \(record.uid.prefix(12))... | 大小: \(formatFileSize(record.file_size))")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .padding()
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(12)
                            .padding(.horizontal, 20)
                        }
                    }
                }
            }
            
            Spacer()
            
            Button(action: goBack) {
                Text("返回上一步")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            Spacer()
        }
    }
    
    private func processIncomingFiles() async {
        shareExtensionLogger.info("🔄 [EXT] processIncomingFiles 开始")
        
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            shareExtensionLogger.error("❌ [EXT] inputItems 为空")
            return
        }
        
        shareExtensionLogger.info("📦 [EXT] 输入项数量: \(inputItems.count)")
        
        for (index, item) in inputItems.enumerated() {
            guard let attachments = item.attachments else { 
                shareExtensionLogger.warning("⚠️ [EXT] 第\(index)项没有附件")
                continue 
            }
            
            shareExtensionLogger.info("📎 [EXT] 第\(index)项附件数量: \(attachments.count)")
            
            for (attachIndex, attachment) in attachments.enumerated() {
                    shareExtensionLogger.info("🔍 [EXT] 检查附件 \(attachIndex): \(attachment)")
                    shareExtensionLogger.info("🔍 [EXT] 附件 \(attachIndex) 类型标识符: \(attachment.registeredTypeIdentifiers)")
                    
                    if attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        shareExtensionLogger.info("✅ [EXT] 附件 \(attachIndex) 符合 fileURL 类型")
                        
                        do {
                            shareExtensionLogger.info("📥 [EXT] 开始加载附件 \(attachIndex)")
                            let loadedItem = try await attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                        
                        guard let url = loadedItem as? URL else {
                            shareExtensionLogger.error("❌ [EXT] 加载的项不是 URL: \(type(of: loadedItem))")
                            continue
                        }
                        
                        shareExtensionLogger.info("📄 [EXT] 加载到 URL: \(url.path, privacy: .public)")
                        
                        originalSourceURL = url
                        
                        let tempURL = try copyToTempInbox(sourceURL: url)
                        tempFilePath = tempURL
                        
                        shareExtensionLogger.info("📁 [EXT] 临时文件路径: \(tempURL.path, privacy: .public)")
                        
                        let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                        fileSize = fileAttributes[.size] as? Int64 ?? 0
                        shareExtensionLogger.info("📐 [EXT] 文件大小: \(fileSize)")
                        
                        let correctedName = try detectAndCorrectFileExtension(fileURL: tempURL)
                        detectedFileName = correctedName
                        
                        shareExtensionLogger.info("📝 [EXT] 检测到文件名: \(correctedName, privacy: .public)")
                        
                        await determineHostType()
                        let hostTypeName = hostType == .wps ? "WPS" : hostType == .external ? "外部" : "未知"
                        shareExtensionLogger.info("🏠 [EXT] 判定宿主类型: \(hostTypeName, privacy: .public)")
                        await determineActionState(tempURL: tempURL, fileName: correctedName)
                        
                    } catch {
                        shareExtensionLogger.error("❌ [EXT] 文件处理失败: \(error)")
                    }
                } else {
                    shareExtensionLogger.warning("⚠️ [EXT] 附件 \(attachIndex) 不符合 fileURL 类型")
                }
            }
        }
        
        shareExtensionLogger.info("✅ [EXT] processIncomingFiles 完成")
    }
    
    private func determineHostType() async {
        hostType = .external
        
        if let sourceURL = originalSourceURL {
            let path = sourceURL.path.lowercased()
            shareExtensionLogger.info("🏠 [EXT] 原始来源路径: \(path, privacy: .public)")
            
            if path.contains("wps") || path.contains("kingsoft") {
                hostType = .wps
                shareExtensionLogger.info("🏠 [EXT] URL路径包含WPS特征，判定为WPS宿主")
            } else {
                hostType = .external
                shareExtensionLogger.info("🏠 [EXT] URL路径为外部来源")
            }
        } else if let tempURL = tempFilePath {
            let path = tempURL.path.lowercased()
            shareExtensionLogger.info("🏠 [EXT] 备用路径(临时文件): \(path, privacy: .public)")
            
            if path.contains("wps") || path.contains("kingsoft") {
                hostType = .wps
                shareExtensionLogger.info("🏠 [EXT] 临时文件路径包含WPS特征，判定为WPS宿主")
            } else {
                hostType = .external
                shareExtensionLogger.info("🏠 [EXT] 临时文件路径为外部来源")
            }
        } else {
            hostType = .external
            shareExtensionLogger.info("🏠 [EXT] 无文件路径，默认判定为外部宿主")
        }
        
        let finalHostTypeName = hostType == .wps ? "WPS" : "外部"
        shareExtensionLogger.info("🏠 [EXT] 最终宿主类型: \(finalHostTypeName, privacy: .public)")
    }
    
    private func determineActionState(tempURL: URL, fileName: String) async {
        shareExtensionLogger.info("🔍 [EXT] ===== 开始确定动作状态 ===== ")
        let actionHostTypeName = hostType == .wps ? "WPS" : "外部"
        shareExtensionLogger.info("🔍 [EXT] 宿主类型: \(actionHostTypeName, privacy: .public)")
        
        let uid = ZipExtraFieldManager.shared.readUid(from: tempURL)
        shareExtensionLogger.info("🔍 [EXT] UID读取结果: \(uid ?? "nil", privacy: .public)")
        let hasMetadata = uid != nil
        
        if hasMetadata {
            shareExtensionLogger.info("✅ [EXT] 检测到尾部存在元数据")
            
            if hostType == .wps {
                shareExtensionLogger.info("🔄 [EXT] 宿主为WPS，进入通路2：纯看未改")
                await enterPath2(tempURL: tempURL, fileName: fileName)
            } else {
                shareExtensionLogger.info("🔑 [EXT] 宿主为外部，进入通路1：统一查密")
                await enterPath1(tempURL: tempURL, fileName: fileName)
            }
        } else {
            shareExtensionLogger.info("❌ [EXT] 检测到尾部无元数据")
            
            if hostType == .wps {
                shareExtensionLogger.info("🔄 [EXT] 宿主为WPS，进入通路4：正常写回")
                await enterPath4(tempURL: tempURL, fileName: fileName)
            } else {
                shareExtensionLogger.info("🌿 [EXT] 宿主为外部，进入通路3：野生文件")
                await enterPath3(tempURL: tempURL, fileName: fileName)
            }
        }
    }
    
    private func enterPath1(tempURL: URL, fileName: String) async {
        if let uid = ZipExtraFieldManager.shared.readUid(from: tempURL) {
            shareExtensionLogger.info("🔑 [通路1] 提取到UID: \(uid)")
            
            matchedUID = uid
            
            if let password = ZipExtraFieldManager.shared.readPassword(from: tempURL) {
                shareExtensionLogger.info("✅ [通路1] 从元数据提取到密码: \(password.prefix(8))...")
                capturedPassword = password
                hasPasswordInMetadata = true
            } else {
                shareExtensionLogger.warning("⚠️ [通路1] 元数据中无密码")
                capturedPassword = ""
                hasPasswordInMetadata = false
            }
            
            _ = AppGroupDBManager.shared.upsertRecord(
                uid: uid,
                fileName: fileName,
                passwordHash: capturedPassword,
                fileSize: fileSize,
                isLocalVault: 0
            )
            
            actionState = .greenCanvas
        } else {
            shareExtensionLogger.error("❌ [通路1] 无法提取UID，降级到野生文件")
            await enterPath3(tempURL: tempURL, fileName: fileName)
        }
    }
    
    private func enterPath2(tempURL: URL, fileName: String) async {
        shareExtensionLogger.info("🔄 [通路2] ===== 进入通路2：纯看未改 ===== ")
        if let uid = ZipExtraFieldManager.shared.readUid(from: tempURL) {
            shareExtensionLogger.info("🔄 [通路2] 提取到UID: \(uid)")
            
            let record = AppGroupDBManager.shared.queryRecordByUID(uid: uid)
            shareExtensionLogger.info("🔄 [通路2] 数据库查询结果: \(record != nil ? "找到记录" : "未找到记录")")
            
            if let record = record {
                shareExtensionLogger.info("✅ [通路2] 数据库找到记录: \(record.file_name)")
                matchedUID = uid
                matchedAssetName = record.file_name
                capturedPassword = record.password_hash
                shareExtensionLogger.info("✅ [通路2] 设置密码: \(capturedPassword.prefix(8))...")
                actionState = .blueCanvasA
            } else {
                shareExtensionLogger.warning("⚠️ [通路2] 数据库无记录，降级到蓝色画布B，保留文件原有UID")
                matchedUID = uid
                actionState = .blueCanvasB
            }
        } else {
            shareExtensionLogger.error("❌ [通路2] 无法提取UID，降级到通路4")
            await enterPath4(tempURL: tempURL, fileName: fileName)
        }
    }
    
    private func enterPath3(tempURL: URL, fileName: String) async {
        shareExtensionLogger.info("🌿 [通路3] 野生文件首次登记")
        
        let isGarbled = fileName.hasPrefix("~") || !fileName.contains(".")
        if isGarbled {
            shareExtensionLogger.info("📝 [通路3] 文件名乱码，已自动纠偏")
        }
        
        actionState = .yellowCanvas
    }
    
    private func enterPath4(tempURL: URL, fileName: String) async {
        shareExtensionLogger.info("🔄 [通路4] ===== 进入通路4：正常写回 ===== ")
        shareExtensionLogger.info("🔄 [通路4] 开始后台密码撞击")
        
        isBruteForcing = true
        
        let task = Task.detached { () -> (FileMappingRecord?, String?) in
            let topRecords = AppGroupDBManager.shared.queryTopActiveRecords(limit: 5)
            shareExtensionLogger.info("📋 [通路4] 获取前\(topRecords.count)条活跃记录")
            
            for (index, record) in topRecords.enumerated() {
                shareExtensionLogger.info("🔐 [通路4] 尝试密码 \(index+1)/\(topRecords.count): \(record.password_hash.prefix(8))...")
                
                let verificationResult = await self.verifyPassword(fileURL: tempURL, password: record.password_hash)
                
                if verificationResult {
                    shareExtensionLogger.info("✅ [通路4] 密码撞击成功! 匹配记录: \(record.file_name)")
                    return (record, record.password_hash)
                }
                
                shareExtensionLogger.info("❌ [通路4] 密码撞击失败")
            }
            
            shareExtensionLogger.info("❌ [通路4] 所有\(topRecords.count)条密码均撞击失败")
            return (nil, nil)
        }
        
        let (matchedRecord, foundPassword) = await task.value
        
        isBruteForcing = false
        
        if let record = matchedRecord, let password = foundPassword {
            matchedUID = record.uid
            matchedAssetName = record.file_name
            capturedPassword = password
            shareExtensionLogger.info("✅ [通路4] 设置状态为 blueCanvasA")
            actionState = .blueCanvasA
        } else {
            shareExtensionLogger.warning("⚠️ [通路4] 所有密码撞击失败，降级到蓝色画布子态B")
            actionState = .blueCanvasB
        }
    }
    
    private func verifyPassword(fileURL: URL, password: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: fileURL, password: password) { result in
                continuation.resume(returning: result == .success(true))
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
    
    private func copyPasswordAndExit() {
        if hasPasswordInMetadata {
            UIPasteboard.general.string = capturedPassword
            shareExtensionLogger.info("✅ [剪贴板] 密码已复制")
        }
        
        if !matchedUID.isEmpty {
            _ = AppGroupDBManager.shared.updateAccessTime(uid: matchedUID)
        }
        
        completeExtension()
    }
    
    private func verifyAndRegisterAsNew() {
        shareExtensionLogger.info("🔑 [登记新文件] verifyAndRegisterAsNew 被调用")
        shareExtensionLogger.info("🔑 [登记新文件] 输入密码长度: \(capturedPassword.count)")
        shareExtensionLogger.info("🔑 [登记新文件] 输入密码内容: \(capturedPassword)")
        shareExtensionLogger.info("🔑 [登记新文件] tempFilePath: \(tempFilePath?.path ?? "nil")")
        
        guard !capturedPassword.isEmpty, let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [登记新文件] 参数无效: 密码为空=\(capturedPassword.isEmpty), 文件路径为nil=\(tempFilePath == nil)")
            verificationError = "请输入密码"
            return
        }
        
        isVerifying = true
        verificationError = nil
        
        shareExtensionLogger.info("🔑 [登记新文件] 开始密码验证，文件: \(tempURL.lastPathComponent)")
        
        OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
            
            let resultDescription: String
            switch result {
            case .success(let value):
                resultDescription = "success(\(value))"
            case .failure(let error):
                resultDescription = "failure(\(error.localizedDescription))"
            }
            shareExtensionLogger.info("🔑 [登记新文件] 密码验证回调返回: \(resultDescription)")
            
            DispatchQueue.main.async {
                self.isVerifying = false
                
                switch result {
                case .success(let verified):
                    if verified {
                        shareExtensionLogger.info("✅ [登记新文件] 密码验证通过，开始注册")
                        self.registerNewFile(password: self.capturedPassword)
                    } else {
                        shareExtensionLogger.warning("⚠️ [登记新文件] 密码验证失败")
                        self.verificationError = "密码验证失败，请重试"
                    }
                case .failure(let error):
                    shareExtensionLogger.error("❌ [登记新文件] 密码验证异常: \(error.localizedDescription)")
                    self.verificationError = error.localizedDescription
                }
            }
        }
    }
    
    private func registerNewFile(password: String) {
        shareExtensionLogger.info("📝 [登记新文件] registerNewFile 被调用")
        shareExtensionLogger.info("📝 [登记新文件] 密码长度: \(password.count)")
        
        guard let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [登记新文件] 文件路径无效")
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = detectedFileName
        let uid = matchedUID.isEmpty ? generateUID() : matchedUID
        
        shareExtensionLogger.info("📝 [登记新文件] 文件名: \(fileName) | UID: \(uid)")
        
        shareExtensionLogger.info("📝 [登记新文件] 开始写入 WPPM 标记")
        let writeSuccess = writeWppmMarkers(tempURL: tempURL, uid: uid, password: password)
        shareExtensionLogger.info("📝 [登记新文件] WPPM 标记写入结果: \(writeSuccess)")
        
        if writeSuccess {
            shareExtensionLogger.info("📝 [登记新文件] 开始迁移到保险箱")
            let moveSuccess = moveToSafeVaultSync(tempURL: tempURL, newFileName: fileName)
            shareExtensionLogger.info("📝 [登记新文件] 迁移结果: \(moveSuccess)")
            
            if moveSuccess {
                shareExtensionLogger.info("📝 [登记新文件] 开始保存数据库记录")
                let dbSuccess = AppGroupDBManager.shared.saveFileMapping(
                    fileName: fileName,
                    uid: uid,
                    passwordHash: password,
                    fileSize: fileSize,
                    isLocalVault: 1
                )
                shareExtensionLogger.info("📝 [登记新文件] 数据库保存结果: \(dbSuccess)")
                
                if dbSuccess {
                    shareExtensionLogger.info("✅ [登记新文件] 所有步骤成功完成")
                    completeExtension()
                } else {
                    shareExtensionLogger.error("❌ [登记新文件] 数据库保存失败")
                    completeExtension(withError: "数据库保存失败")
                }
            } else {
                shareExtensionLogger.error("❌ [登记新文件] 文件迁移失败")
                completeExtension(withError: "文件迁移失败")
            }
        } else {
            shareExtensionLogger.error("❌ [登记新文件] WPPM 标记写入失败")
            completeExtension(withError: "写入标记失败")
        }
    }
    
    private func moveToSafeVaultSync(tempURL: URL, newFileName: String) -> Bool {
        do {
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ) else {
                shareExtensionLogger.error("❌ [迁移同步] 无法获取App Group容器")
                return false
            }
            
            let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
            try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            
            var destURL = vaultDir.appendingPathComponent(newFileName)
            
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            
            let coordinator = NSFileCoordinator()
            var error: NSError?
            var moveCompleted = false
            
            coordinator.coordinate(writingItemAt: tempURL, options: .forMoving, error: &error) { newURL in
                do {
                    try FileManager.default.moveItem(at: newURL, to: destURL)
                    
                    var resourceValues = URLResourceValues()
                    resourceValues.isExcludedFromBackup = true
                    try destURL.setResourceValues(resourceValues)
                    
                    shareExtensionLogger.info("✅ [迁移同步] 文件迁移成功: \(destURL.path)")
                    moveCompleted = true
                } catch {
                    shareExtensionLogger.error("❌ [迁移同步] 文件迁移失败: \(error)")
                }
            }
            
            if let error = error {
                shareExtensionLogger.error("❌ [迁移同步] 文件协调失败: \(error)")
                return false
            }
            
            return moveCompleted && FileManager.default.fileExists(atPath: destURL.path)
            
        } catch {
            shareExtensionLogger.error("❌ [迁移同步] 文件迁移异常: \(error)")
            return false
        }
    }
    
    private func syncOverrideAction() {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = matchedAssetName
        let uid = matchedUID
        
        shareExtensionLogger.info("🔄 [同步覆盖] 目标: \(fileName) | UID: \(uid)")
        
        Task.detached {
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: nil)
            
            if success {
                let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: fileName)
                
                await MainActor.run {
                    if moveSuccess {
                        _ = AppGroupDBManager.shared.saveFileMapping(
                            fileName: fileName,
                            uid: uid,
                            passwordHash: capturedPassword,
                            fileSize: fileSize,
                            isLocalVault: 1
                        )
                        shareExtensionLogger.info("✅ [同步覆盖] 成功")
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
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let baseName = URL(fileURLWithPath: detectedFileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: detectedFileName).pathExtension.isEmpty ? "" : ".\(URL(fileURLWithPath: detectedFileName).pathExtension)"
        let timestamp = String(Date().timeIntervalSince1970).prefix(10)
        let newFileName = "\(baseName)_sync_\(timestamp)\(ext)"
        
        let uid = generateUID()
        
        shareExtensionLogger.info("➕ [另存为新文件] 新文件名: \(newFileName) | UID: \(uid)")
        
        Task.detached {
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: nil)
            
            if success {
                let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: newFileName)
                
                await MainActor.run {
                    if moveSuccess {
                        _ = AppGroupDBManager.shared.saveFileMapping(
                            fileName: newFileName,
                            uid: uid,
                            passwordHash: capturedPassword,
                            fileSize: fileSize,
                            isLocalVault: 1
                        )
                        shareExtensionLogger.info("✅ [另存为新文件] 成功")
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
    
    private func overrideWithNewPassword() {
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
                        if !matchedUID.isEmpty {
                            let fileName = detectedFileName
                            let uid = matchedUID
                            let password = capturedPassword
                            shareExtensionLogger.info("🔄 [保留身份] 使用文件原有UID: \(uid)")
                            
                            Task.detached {
                                let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: password)
                                
                                if success {
                                    let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: fileName)
                                    
                                    await MainActor.run {
                                        if moveSuccess {
                                            _ = AppGroupDBManager.shared.saveFileMapping(
                                                fileName: fileName,
                                                uid: uid,
                                                passwordHash: capturedPassword,
                                                fileSize: self.fileSize,
                                                isLocalVault: 1
                                            )
                                            self.completeExtension()
                                        } else {
                                            self.completeExtension(withError: "文件迁移失败")
                                        }
                                    }
                                } else {
                                    await MainActor.run {
                                        self.completeExtension(withError: "写入标记失败")
                                    }
                                }
                            }
                        } else {
                            let fileName = detectedFileName
                            let existingRecords = AppGroupDBManager.shared.queryRecordsByFileName(fileName: fileName)
                            
                            if let existingRecord = existingRecords.first {
                                let uid = existingRecord.uid
                                let password = capturedPassword
                                shareExtensionLogger.info("🔄 [覆盖同名] 使用老UID: \(uid)")
                                
                                Task.detached {
                                    let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: password)
                                    
                                    if success {
                                        let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: fileName)
                                        
                                        await MainActor.run {
                                            if moveSuccess {
                                                _ = AppGroupDBManager.shared.saveFileMapping(
                                                    fileName: fileName,
                                                    uid: uid,
                                                    passwordHash: capturedPassword,
                                                    fileSize: self.fileSize,
                                                    isLocalVault: 1
                                                )
                                                self.completeExtension()
                                            } else {
                                                self.completeExtension(withError: "文件迁移失败")
                                            }
                                        }
                                    } else {
                                        await MainActor.run {
                                            self.completeExtension(withError: "写入标记失败")
                                        }
                                    }
                                }
                            } else {
                                registerNewFile(password: capturedPassword)
                            }
                        }
                    } else {
                        verificationError = "密码验证失败，请重试"
                    }
                case .failure(let error):
                    verificationError = error.localizedDescription
                }
            }
        }
    }
    
    private func showAssetSelection() {
        assetList = AppGroupDBManager.shared.queryAllLocalVaultRecords()
        actionState = .stateD
    }
    
    private func selectAsset(record: FileMappingRecord) {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let uid = record.uid
        let fileName = record.file_name
        let password = capturedPassword
        
        shareExtensionLogger.info("🎯 [状态D] 选择资产: \(fileName) | UID: \(uid)")
        
        Task.detached {
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, password: password)
            
            if success {
                let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: fileName)
                
                await MainActor.run {
                    if moveSuccess {
                            _ = AppGroupDBManager.shared.saveFileMapping(
                                fileName: fileName,
                                uid: uid,
                                passwordHash: capturedPassword,
                                fileSize: self.fileSize,
                                isLocalVault: 1
                            )
                            shareExtensionLogger.info("✅ [状态D] 覆盖成功")
                        self.completeExtension()
                    } else {
                        self.completeExtension(withError: "文件迁移失败")
                    }
                }
            } else {
                await MainActor.run {
                    self.completeExtension(withError: "写入标记失败")
                }
            }
        }
    }
    
    private func goBack() {
        actionState = .yellowCanvas
    }
    
    private func generateUID() -> String {
        return UidGenerator.shared.createUid()
    }
    
    private nonisolated func writeWppmMarkers(tempURL: URL, uid: String, password: String?) -> Bool {
        return ZipExtraFieldManager.shared.writeMetadata(
            to: tempURL,
            uid: uid,
            password: password,
            keyVersion: "default"
        )
    }
    
    private func moveToSafeVault(tempURL: URL, newFileName: String) async -> Bool {
        do {
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ) else {
                shareExtensionLogger.error("❌ [迁移] 无法获取App Group容器")
                return false
            }
            
            let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
            try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            
            var destURL = vaultDir.appendingPathComponent(newFileName)
            
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
                    
                    shareExtensionLogger.info("✅ [迁移] 文件迁移成功: \(destURL.path)")
                } catch {
                    shareExtensionLogger.error("❌ [迁移] 文件迁移失败: \(error)")
                }
            }
            
            if let error = error {
                shareExtensionLogger.error("❌ [迁移] 文件协调失败: \(error)")
                return false
            }
            
            return FileManager.default.fileExists(atPath: destURL.path)
            
        } catch {
            shareExtensionLogger.error("❌ [迁移] 文件迁移异常: \(error)")
            return false
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
    
    private func completeExtension(withError errorMessage: String? = nil) {
        if let error = errorMessage {
            shareExtensionLogger.error("❌ [扩展退出] 错误: \(error)")
        }
        
        shareExtensionLogger.info("👋 [扩展退出] 即将调用 completeRequest")
        
        extensionContext?.completeRequest(returningItems: [], completionHandler: { _ in
            shareExtensionLogger.info("✅ [扩展退出] completeRequest 调用完成")
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