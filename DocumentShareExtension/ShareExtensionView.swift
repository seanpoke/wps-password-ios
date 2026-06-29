import SwiftUI
import UniformTypeIdentifiers
import Foundation
import OSLog

let shareExtensionLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "ShareExtension")

@MainActor
enum ActionState: CustomStringConvertible {
    case identifying
    case loginCanvas
    case greenCanvas
    case yellowCanvas
    case blueCanvasA
    case blueCanvasB
    case stateD
    case actionDeny
    
    var description: String {
        switch self {
        case .identifying: return "identifying"
        case .loginCanvas: return "loginCanvas"
        case .greenCanvas: return "greenCanvas"
        case .yellowCanvas: return "yellowCanvas"
        case .blueCanvasA: return "blueCanvasA"
        case .blueCanvasB: return "blueCanvasB"
        case .stateD: return "stateD"
        case .actionDeny: return "actionDeny"
        }
    }
}

@MainActor
enum PendingAction {
    case none
    case syncOverride
    case saveAsNew(newFileName: String)
    case associateOverride
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
    @State private var matchedIsLocalVault: Int = 0
    @State private var capturedPassword: String = ""
    @State private var isVerifying: Bool = false
    @State private var verificationError: String?
    @State private var fileSize: Int64 = 0
    @State private var isBruteForcing: Bool = false
    @State private var hasPasswordInMetadata: Bool = false
    @State private var isEncryptedFile: Bool = true
    
    @State private var assetList: [FileMappingRecord] = []
    @State private var showAssetList: Bool = false
    
    @State private var showRenameDialog: Bool = false
    @State private var newFileNameInput: String = ""
    @State private var fileExtension: String = ""
    
    @State private var previousState: ActionState = .yellowCanvas
    
    @State private var showPasswordInputDialog: Bool = false
    @State private var pendingAction: PendingAction = .none
    
    @State private var ownerAccount: String = ""
    @State private var loginAccount = ""
    @State private var loginPassword = ""
    @State private var loginDomain = ""
    @State private var loginPort = ""
    @State private var loginRememberPassword = false
    @State private var loginIsLoading = false
    @State private var loginErrorMessage = ""
    @State private var loginDomainError = ""
    
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
            case .loginCanvas:
                loginCanvasView
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
            case .actionDeny:
                denyCanvasView
                    .background(Color.gray)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .overlay {
            if showRenameDialog {
                renameDialogView
            }
            if showPasswordInputDialog {
                passwordInputDialogView
            }
        }
        .onAppear {
            shareExtensionLogger.info("✅ [EXT] ===== View onAppear 触发 ===== ")
            loadSavedLoginCredentials()
            Task {
                let authSuccess = await bootstrapAuth()
                if !authSuccess {
                    shareExtensionLogger.info("🔐 [EXT] 认证失败，跳转到登录页")
                    actionState = .loginCanvas
                    return
                }
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
    
    private var loginCanvasView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60)
            
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    InputField(
                        label: "账号",
                        placeholder: "请输入账号",
                        text: $loginAccount,
                        keyboardType: .emailAddress
                    )
                    
                    InputField(
                        label: "密码",
                        placeholder: "请输入密码",
                        text: $loginPassword,
                        isSecure: true
                    )
                    
                    InputField(
                        label: "域名",
                        placeholder: "请输入服务器域名或IP",
                        text: $loginDomain,
                        errorMessage: loginDomainError
                    )
                    .onChange(of: loginDomain) {
                        validateLoginDomain()
                    }
                    
                    InputField(
                        label: "端口",
                        placeholder: "请输入端口号",
                        text: $loginPort,
                        keyboardType: .numberPad
                    )
                    
                    HStack(spacing: 8) {
                        Button(action: {
                            loginRememberPassword.toggle()
                        }) {
                            Image(systemName: loginRememberPassword ? "checkmark.square.fill" : "square")
                                .foregroundColor(loginRememberPassword ? .blue : .gray)
                                .font(.system(size: 20))
                        }
                        
                        Text("记住密码")
                            .font(.body)
                            .foregroundColor(.white)
                        
                        Spacer()
                    }
                }
                
                if !loginErrorMessage.isEmpty {
                    Text(loginErrorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                
                Button(action: performLogin) {
                    if loginIsLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                    } else {
                        Text("登录")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                    }
                }
                .disabled(loginIsLoading || !loginIsFormValid)
                .opacity(loginIsLoading || !loginIsFormValid ? 0.6 : 1.0)
            }
            .padding()
            
            Spacer(minLength: 60)
        }
        .frame(maxHeight: .infinity)
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
                Text(hasPasswordInMetadata ? "复制密码" : "当前文档无密码")
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
            
            Image(systemName: isEncryptedFile ? "key.fill" : "file")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text("识别到新文件")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(isEncryptedFile ? "检测到加密文件: \(detectedFileName)" : "检测到文件: \(detectedFileName)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(12)
            }
            
            if isEncryptedFile {
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
            }
            
            if isVerifying {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2)
            } else {
                VStack(spacing: 16) {
                    Button(action: isEncryptedFile ? verifyAndRegisterAsNew : registerNewFileWithoutPassword) {
                        Text("文件另存为")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
                    .padding(.horizontal, 20)
                    
                    Button(action: isEncryptedFile ? verifyAndShowAssetSelection : showAssetSelection) {
                        Text("覆盖其他文件")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
                    .padding(.horizontal, 20)
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
                Text("保存文件")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(matchedIsLocalVault == 1 ? "匹配到文件: \(matchedAssetName)" : "匹配到记录: \(matchedAssetName)")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(12)
            }
            
            VStack(spacing: 16) {
                Button(action: syncOverrideAction) {
                    Text("同步覆盖")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(radius: 8)
                }
                .padding(.horizontal, 20)
                
                Button(action: saveAsNewAction) {
                    Text("文件另存为")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(16)
                        .shadow(radius: 8)
                }
                .padding(.horizontal, 20)
                
                Button(action: verifyAndShowAssetSelectionFromBlueA) {
                    Text("覆盖其他文件")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(16)
                        .shadow(radius: 8)
                }
                .padding(.horizontal, 20)
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
            
            Image(systemName: isEncryptedFile ? "lock.fill" : "file")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text(matchedUID.isEmpty ? (isEncryptedFile ? "密码撞击失败" : "识别到新文件") : "需要验证身份")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(isEncryptedFile ? (matchedUID.isEmpty ? "检测到: \(detectedFileName)" : "检测到身份标识: \(detectedFileName)") : "检测到文件: \(detectedFileName)")
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
            
            if isEncryptedFile {
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
            }
            
            if isVerifying {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2)
            } else {
                VStack(spacing: 16) {
                    Button(action: isEncryptedFile ? verifyPasswordAndSaveAsNewFromBlueB : saveAsNewAction) {
                        Text("文件另存为")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
                    .padding(.horizontal, 20)
                    
                    Button(action: isEncryptedFile ? verifyAndShowAssetSelection : showAssetSelection) {
                        Text("覆盖其他文件")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(16)
                            .shadow(radius: 8)
                    }
                    .padding(.horizontal, 20)
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
                    ForEach(assetList, id: \.id) { record in
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
    
    private var denyCanvasView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            Image(systemName: "lock.shield")
                .font(.system(size: 80))
                .foregroundColor(.white)
                .shadow(radius: 10)
            
            VStack(spacing: 12) {
                Text("无法访问权限")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("您没有该文档的访问权限")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(12)
            }
            
            VStack(spacing: 8) {
                Text("检测到: \(detectedFileName)")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                if !ownerAccount.isEmpty {
                    Text("所属人: \(ownerAccount)")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            
            Button(action: cancelAction) {
                Text("关闭")
                    .font(.headline)
                    .foregroundColor(.gray)
                    .padding()
                    .frame(maxWidth: 280)
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(radius: 8)
            }
            
            Spacer()
        }
    }
    
    private var renameDialogView: some View {
        ZStack {
            Color.black.opacity(0.5)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    showRenameDialog = false
                }
            
            VStack(spacing: 24) {
                Spacer()
                
                VStack(spacing: 20) {
                    Image(systemName: "file.badge.plus")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("文件另存为")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text("请输入新文件的名称")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    
                    HStack(spacing: 8) {
                        TextField("请输入新文件名", text: $newFileNameInput)
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(12)
                            .frame(maxWidth: .infinity)
                        
                        Text(fileExtension)
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.vertical, 12)
                            .padding(.trailing, 16)
                    }
                    .padding(.horizontal, 20)
                    
                    if let error = verificationError {
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                    
                    VStack(spacing: 12) {
                        Button(action: confirmRename) {
                            Text("确定")
                                .font(.headline)
                                .foregroundColor(.blue)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.white)
                                .cornerRadius(16)
                                .shadow(radius: 8)
                        }
                        .padding(.horizontal, 20)
                        
                        Button(action: {
                            showRenameDialog = false
                            verificationError = nil
                        }) {
                            Text("取消")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(30)
                .background(Color.black.opacity(0.7))
                .cornerRadius(32)
                .frame(maxWidth: .infinity)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .edgesIgnoringSafeArea(.all)
    }
    
    private var passwordInputDialogView: some View {
        ZStack {
            Color.black.opacity(0.5)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    showPasswordInputDialog = false
                    pendingAction = .none
                }
            
            VStack(spacing: 24) {
                Spacer()
                
                VStack(spacing: 20) {
                    Text("请输入文件密码")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text("密码验证失败，请重新输入")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    
                    SecureField("请输入密码", text: $capturedPassword)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(12)
                        .padding(.horizontal, 20)
                    
                    if let error = verificationError {
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                    
                    VStack(spacing: 12) {
                        Button(action: confirmPasswordInput) {
                            Text("确定")
                                .font(.headline)
                                .foregroundColor(.blue)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.white)
                                .cornerRadius(16)
                                .shadow(radius: 8)
                        }
                        .padding(.horizontal, 20)
                        
                        Button(action: {
                            showPasswordInputDialog = false
                            pendingAction = .none
                            verificationError = nil
                        }) {
                            Text("取消")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(30)
                .background(Color.black.opacity(0.7))
                .cornerRadius(32)
                .frame(maxWidth: .infinity)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .edgesIgnoringSafeArea(.all)
    }
    
    private func confirmPasswordInput() {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        if isEncryptedFile {
            if capturedPassword.isEmpty {
                verificationError = "请输入密码"
                return
            }
            
            isVerifying = true
            
            OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
                Task { @MainActor in
                    self.isVerifying = false
                    
                    switch result {
                    case .success(let verified):
                        if verified {
                            self.showPasswordInputDialog = false
                            self.verificationError = nil
                            self.executePendingAction()
                        } else {
                            self.verificationError = "密码验证失败，请重试"
                        }
                    case .failure(let error):
                        self.verificationError = error.localizedDescription
                    }
                }
            }
        } else {
            showPasswordInputDialog = false
            verificationError = nil
            executePendingAction()
        }
    }
    
    private func executePendingAction() {
        switch pendingAction {
        case .syncOverride:
            performSyncOverride(fileName: matchedAssetName, uid: matchedUID, password: capturedPassword)
        case .saveAsNew(let newFileName):
            performSaveAsNew(newFileName: newFileName, password: capturedPassword)
        case .associateOverride:
            showAssetSelection()
        case .none:
            break
        }
        pendingAction = .none
    }
    
    private func loadSavedLoginCredentials() {
        let savedAccount = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.account) ?? ""
        let savedPassword = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.password) ?? ""
        let savedDomain = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.domain) ?? ""
        let savedPort = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.port) ?? ""
        let savedRememberPassword = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.rememberPassword) ?? "false"

        loginRememberPassword = savedRememberPassword == "true"

        if loginRememberPassword {
            loginAccount = savedAccount
            loginPassword = savedPassword
        } else {
            loginAccount = savedAccount
        }
        loginDomain = savedDomain
        loginPort = savedPort
    }
    
    private var loginIsFormValid: Bool {
        !loginAccount.isEmpty && !loginPassword.isEmpty && !loginDomain.isEmpty && loginDomainError.isEmpty
    }
    
    private func validateLoginDomain() {
        let trimmedDomain = loginDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedDomain.isEmpty {
            loginDomainError = ""
            return
        }
        
        if trimmedDomain.hasPrefix("http://") {
            loginDomainError = "仅支持HTTPS协议"
            return
        }
        
        loginDomainError = ""
    }
    
    private func normalizeLoginDomain() -> String {
        var normalized = loginDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        
        if normalized.hasPrefix("http://") {
            normalized = normalized.replacingOccurrences(of: "http://", with: "https://")
        }
        
        return normalized
    }
    
    private func performLogin() {
        guard loginIsFormValid else {
            loginErrorMessage = "请填写完整的登录信息"
            return
        }
        
        loginIsLoading = true
        loginErrorMessage = ""
        
        let normalizedDomain = normalizeLoginDomain()
        
        APIService.shared.login(account: loginAccount, password: loginPassword, domain: normalizedDomain, port: loginPort, rememberPassword: loginRememberPassword) { result in
            DispatchQueue.main.async {
                self.loginIsLoading = false
                
                switch result {
                case .success:
                    shareExtensionLogger.info("✅ [EXT] 登录成功，开始执行文件处理")
                    Task {
                        await self.processIncomingFiles()
                        shareExtensionLogger.info("✅ [EXT] 登录后 processIncomingFiles 执行完毕，当前状态: \(self.actionState)")
                    }
                    
                case .failure(let error):
                    self.loginErrorMessage = error.localizedDescription
                    shareExtensionLogger.error("❌ [EXT] 登录失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func bootstrapAuth() async -> Bool {
        shareExtensionLogger.info("🔐 [EXT] 启动认证初始化")
        return await withCheckedContinuation { continuation in
            APIService.shared.bootstrap { result in
                switch result {
                case .success(let bootstrapResult):
                    if bootstrapResult.isAuthenticated {
                        shareExtensionLogger.info("✅ [EXT] Token刷新成功")
                        continuation.resume(returning: true)
                    } else {
                        shareExtensionLogger.info("ℹ️ [EXT] 未登录，跳过认证")
                        continuation.resume(returning: false)
                    }
                case .failure(let error):
                    shareExtensionLogger.error("❌ [EXT] 认证初始化失败: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
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
                        
                        let fileExtension = url.pathExtension.lowercased()
                        if !["docx", "pptx", "xlsx"].contains(fileExtension) {
                            shareExtensionLogger.warning("⚠️ [EXT] 文件类型不支持: \(fileExtension)")
                            completeExtension(withError: "仅支持 docx、pptx、xlsx 类型文件")
                            return
                        }
                        shareExtensionLogger.info("✅ [EXT] 文件类型支持: \(fileExtension)")
        
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
                        
                        isEncryptedFile = OfficeCryptoVerifier.shared.isFileEncrypted(fileURL: tempURL)
                        shareExtensionLogger.info("🔐 [EXT] 文件加密状态: \(isEncryptedFile ? "已加密" : "未加密")")
                        
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
            
            if path.contains("wps_share_temp_dir") {
                hostType = .wps
                shareExtensionLogger.info("🏠 [EXT] URL路径包含WPS分享临时目录特征，判定为WPS宿主")
            } else {
                hostType = .external
                shareExtensionLogger.info("🏠 [EXT] URL路径为外部来源")
            }
        } else if let tempURL = tempFilePath {
            let path = tempURL.path.lowercased()
            shareExtensionLogger.info("🏠 [EXT] 备用路径(临时文件): \(path, privacy: .public)")
            
            if path.contains("wps_share_temp_dir") {
                hostType = .wps
                shareExtensionLogger.info("🏠 [EXT] 临时文件路径包含WPS分享临时目录特征，判定为WPS宿主")
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
    
    private func fetchPlainPassword(uid: String, encryPassword: String, completion: @escaping (String?) -> Void) {
        APIService.shared.fetchDocPassword(docId: uid, encryPassword: encryPassword, isTemp: false) { result in
            switch result {
            case .success(let password):
                shareExtensionLogger.info("✅ [获取明文密码] 成功")
                completion(password)
            case .failure(let error):
                shareExtensionLogger.error("❌ [获取明文密码] 失败: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }
    
    private func enterPath1(tempURL: URL, fileName: String) async {
        if let uid = ZipExtraFieldManager.shared.readUid(from: tempURL) {
            shareExtensionLogger.info("🔑 [通路1] 提取到UID: \(uid)")
            
            matchedUID = uid
            
            let encryPassword = ZipExtraFieldManager.shared.readPassword(from: tempURL)
            if let encryPassword = encryPassword {
                shareExtensionLogger.info("✅ [通路1] 从元数据提取到加密密码")
            } else {
                shareExtensionLogger.warning("⚠️ [通路1] 元数据中无密码")
            }
            
            await queryOwnerAndRouteForGreenCanvas(uid: uid, fileName: fileName, encryPassword: encryPassword)
        } else {
            shareExtensionLogger.error("❌ [通路1] 无法提取UID，降级到野生文件")
            await enterPath3(tempURL: tempURL, fileName: fileName)
        }
    }
    
    private func queryOwnerAndRouteForGreenCanvas(uid: String, fileName: String, encryPassword: String?) async {
        shareExtensionLogger.info("🔍 [通路1] ===== 开始调用文档所属人接口 =====")
        shareExtensionLogger.info("🔍 [通路1] docId(UID): \(uid, privacy: .public) | fileName: \(fileName, privacy: .public)")
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            APIService.shared.fetchDocOwner(docId: uid, fileName: fileName) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let info):
                        shareExtensionLogger.info("✅ [通路1] 所属人接口返回成功 | owner: \(info.ownerAccount, privacy: .public) | read: \(info.readAuth) | write: \(info.writeAuth)")
                        self.ownerAccount = info.ownerAccount
                        if info.hasAnyAuth {
                            shareExtensionLogger.info("✅ [通路1] 拥有读/写权限，开始解密密码")
                            if let encryPassword = encryPassword {
                                self.fetchPlainPassword(uid: uid, encryPassword: encryPassword) { plainPassword in
                                    self.capturedPassword = plainPassword ?? ""
                                    self.hasPasswordInMetadata = plainPassword != nil
                                    if plainPassword == nil {
                                        shareExtensionLogger.warning("⚠️ [通路1] 获取明文密码失败")
                                    }
                                    self.actionState = .greenCanvas
                                }
                            } else {
                                shareExtensionLogger.info("⚠️ [通路1] 无加密密码，直接进入绿色画布")
                                self.capturedPassword = ""
                                self.hasPasswordInMetadata = false
                                self.actionState = .greenCanvas
                            }
                        } else {
                            shareExtensionLogger.warning("⚠️ [通路1] 无任何读/写权限，进入无法访问权限灰色画布")
                            self.actionState = .actionDeny
                        }
                    case .failure(let error):
                        shareExtensionLogger.error("❌ [通路1] 所属人接口调用失败: \(error.localizedDescription)，降级到绿色画布")
                        self.ownerAccount = ""
                        self.actionState = .greenCanvas
                    }
                    continuation.resume()
                }
            }
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
                matchedIsLocalVault = record.is_local_vault
                
                if !record.password.isEmpty {
                    shareExtensionLogger.info("✅ [通路2] 数据库有明文密码，直接使用")
                    capturedPassword = record.password
                    actionState = .blueCanvasA
                } else {
                    shareExtensionLogger.warning("⚠️ [通路2] 数据库中密码为空")
                    capturedPassword = ""
                    actionState = .blueCanvasA
                }
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
                shareExtensionLogger.info("🔐 [通路4] 尝试记录 \(index+1)/\(topRecords.count): \(record.file_name)")
                
                let plainPassword = await self.fetchPlainPasswordAsync(uid: record.uid, encryPassword: record.password)
                
                if let plainPassword = plainPassword {
                    shareExtensionLogger.info("🔐 [通路4] 获取到明文密码，开始验证")
                    let verificationResult = await self.verifyPassword(fileURL: tempURL, password: plainPassword)
                    
                    if verificationResult {
                        shareExtensionLogger.info("✅ [通路4] 密码撞击成功! 匹配记录: \(record.file_name)")
                        return (record, plainPassword)
                    }
                    
                    shareExtensionLogger.info("❌ [通路4] 密码撞击失败")
                } else {
                    shareExtensionLogger.warning("⚠️ [通路4] 获取明文密码失败，跳过该记录")
                }
            }
            
            shareExtensionLogger.info("❌ [通路4] 所有\(topRecords.count)条密码均撞击失败")
            return (nil, nil)
        }
        
        let (matchedRecord, foundPassword) = await task.value
        
        isBruteForcing = false
        
        if let record = matchedRecord, let password = foundPassword {
            matchedUID = record.uid
            matchedAssetName = record.file_name
            matchedIsLocalVault = record.is_local_vault
            capturedPassword = password
            shareExtensionLogger.info("✅ [通路4] 设置状态为 blueCanvasA")
            actionState = .blueCanvasA
        } else {
            shareExtensionLogger.warning("⚠️ [通路4] 所有密码撞击失败，降级到蓝色画布子态B")
            actionState = .blueCanvasB
        }
    }
    
    private func fetchPlainPasswordAsync(uid: String, encryPassword: String) async -> String? {
        return await withCheckedContinuation { continuation in
            APIService.shared.fetchDocPassword(docId: uid, encryPassword: encryPassword, isTemp: false) { result in
                switch result {
                case .success(let password):
                    continuation.resume(returning: password)
                case .failure(let error):
                    shareExtensionLogger.error("❌ [获取明文密码] 失败: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
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
            let existingRecords = AppGroupDBManager.shared.queryRecordsByUID(uid: matchedUID)
            if !existingRecords.isEmpty {
                shareExtensionLogger.info("✅ [通路1] 数据库已有同UID记录，仅更新访问时间")
                let ids = existingRecords.map { $0.id }
                _ = AppGroupDBManager.shared.updateAccessTime(ids: ids)
            } else {
                shareExtensionLogger.info("✅ [通路1] 数据库无同UID记录，插入新记录 | owner: \(self.ownerAccount, privacy: .public)")
                _ = AppGroupDBManager.shared.insertRecord(
                    uid: matchedUID,
                    fileName: detectedFileName,
                    passwordHash: capturedPassword,
                    fileSize: fileSize,
                    isLocalVault: 0,
                    ownerAccount: ownerAccount
                )
            }
        }
        
        completeExtension()
    }
    
    private func registerNewFileWithoutPassword() {
        shareExtensionLogger.info("📝 [普通文件] registerNewFileWithoutPassword 被调用")
        
        guard let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [普通文件] 文件路径无效")
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = detectedFileName
        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension.isEmpty ? "" : ".\(URL(fileURLWithPath: fileName).pathExtension)"
        
        newFileNameInput = baseName
        fileExtension = ext
        showRenameDialog = true
    }
    
    private func verifyAndRegisterAsNew() {
        shareExtensionLogger.info("🔑 [识别到新文件] verifyAndRegisterAsNew 被调用")
        shareExtensionLogger.info("🔑 [识别到新文件] 输入密码长度: \(capturedPassword.count)")
        shareExtensionLogger.info("🔑 [识别到新文件] 输入密码内容: \(capturedPassword)")
        shareExtensionLogger.info("🔑 [识别到新文件] tempFilePath: \(tempFilePath?.path ?? "nil")")
        
        guard !capturedPassword.isEmpty, let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [识别到新文件] 参数无效: 密码为空=\(capturedPassword.isEmpty), 文件路径为nil=\(tempFilePath == nil)")
            verificationError = "请输入密码"
            return
        }
        
        isVerifying = true
        verificationError = nil
        
        shareExtensionLogger.info("🔑 [识别到新文件] 开始密码验证，文件: \(tempURL.lastPathComponent)")
        
        OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
            
            let resultDescription: String
            switch result {
            case .success(let value):
                resultDescription = "success(\(value))"
            case .failure(let error):
                resultDescription = "failure(\(error.localizedDescription))"
            }
            shareExtensionLogger.info("🔑 [识别到新文件] 密码验证回调返回: \(resultDescription)")
            
            DispatchQueue.main.async {
                self.isVerifying = false
                
                switch result {
                case .success(let verified):
                    if verified {
                        shareExtensionLogger.info("✅ [识别到新文件] 密码验证通过，开始注册")
                        self.registerNewFile(password: self.capturedPassword)
                    } else {
                        shareExtensionLogger.warning("⚠️ [识别到新文件] 密码验证失败")
                        self.verificationError = "密码验证失败，请重试"
                    }
                case .failure(let error):
                    shareExtensionLogger.error("❌ [识别到新文件] 密码验证异常: \(error.localizedDescription)")
                    self.verificationError = error.localizedDescription
                }
            }
        }
    }
    
    private func verifyAndShowAssetSelection() {
        shareExtensionLogger.info("🔑 [关联覆盖] verifyAndShowAssetSelection 被调用")
        shareExtensionLogger.info("🔑 [关联覆盖] 输入密码长度: \(capturedPassword.count)")
        shareExtensionLogger.info("🔑 [关联覆盖] tempFilePath: \(tempFilePath?.path ?? "nil")")
        
        guard !capturedPassword.isEmpty, let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [关联覆盖] 参数无效: 密码为空=\(capturedPassword.isEmpty), 文件路径为nil=\(tempFilePath == nil)")
            verificationError = "请输入密码"
            return
        }
        
        isVerifying = true
        verificationError = nil
        
        shareExtensionLogger.info("🔑 [关联覆盖] 开始密码验证，文件: \(tempURL.lastPathComponent)")
        
        OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
            let resultDescription: String
            switch result {
            case .success(let value):
                resultDescription = "success(\(value))"
            case .failure(let error):
                resultDescription = "failure(\(error.localizedDescription))"
            }
            shareExtensionLogger.info("🔑 [关联覆盖] 密码验证回调返回: \(resultDescription)")
            
            DispatchQueue.main.async {
                self.isVerifying = false
                
                switch result {
                case .success(let verified):
                    if verified {
                        shareExtensionLogger.info("✅ [关联覆盖] 密码验证通过，显示资产选择列表")
                        self.showAssetSelection()
                    } else {
                        shareExtensionLogger.warning("⚠️ [关联覆盖] 密码验证失败")
                        self.verificationError = "密码验证失败，请重试"
                    }
                case .failure(let error):
                    shareExtensionLogger.error("❌ [关联覆盖] 密码验证异常: \(error.localizedDescription)")
                    self.verificationError = error.localizedDescription
                }
            }
        }
    }
    
    private func registerNewFile(password: String) {
        shareExtensionLogger.info("📝 [识别到新文件] registerNewFile 被调用")
        shareExtensionLogger.info("📝 [识别到新文件] 密码长度: \(password.count)")
        
        guard let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [识别到新文件] 文件路径无效")
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = detectedFileName
        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension.isEmpty ? "" : ".\(URL(fileURLWithPath: fileName).pathExtension)"
        
        newFileNameInput = baseName
        fileExtension = ext
        showRenameDialog = true
    }
    
    private func fileNameExistsInVault(fileName: String) -> Bool {
        shareExtensionLogger.info("🔍 [保险箱检查] ===== fileNameExistsInVault 开始 =====")
        shareExtensionLogger.info("🔍 [保险箱检查] 检查文件名: \(fileName)")
        shareExtensionLogger.info("🔍 [保险箱检查] appGroupID: \(appGroupID)")
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            shareExtensionLogger.error("❌ [保险箱检查] 无法获取App Group容器，appGroupID=\(appGroupID)")
            return false
        }
        
        shareExtensionLogger.info("🔍 [保险箱检查] App Group容器路径: \(containerURL.path)")
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        shareExtensionLogger.info("🔍 [保险箱检查] 保险箱目录路径: \(vaultDir.path)")
        shareExtensionLogger.info("🔍 [保险箱检查] safeVaultDir常量值: \(safeVaultDir)")
        
        // 确保保险箱目录存在，否则文件检查会失败
        let vaultDirExists = FileManager.default.fileExists(atPath: vaultDir.path)
        shareExtensionLogger.info("🔍 [保险箱检查] 保险箱目录是否存在: \(vaultDirExists)")
        
        if !vaultDirExists {
            do {
                try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
                shareExtensionLogger.info("📁 [保险箱检查] 创建保险箱目录成功: \(vaultDir.path)")
            } catch {
                shareExtensionLogger.error("❌ [保险箱检查] 创建保险箱目录失败: \(error)")
                return false
            }
        }
        
        // 大小写不敏感检查
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: vaultDir.path)
            for file in files {
                if file.lowercased() == fileName.lowercased() {
                    shareExtensionLogger.info("🔍 [保险箱检查] 找到匹配文件（大小写不敏感）: \(file)")
                    return true
                }
            }
            shareExtensionLogger.info("🔍 [保险箱检查] 文件存在检查结果: false")
            return false
        } catch {
            shareExtensionLogger.warning("⚠️ [保险箱检查] 无法列出保险箱目录内容: \(error)")
            return false
        }
    }
    
    private func performRegisterNewFile(password: String, fileName: String) {
        shareExtensionLogger.info("📝 [识别到新文件] 开始注册，文件名: \(fileName)")
        
        guard let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [识别到新文件] 文件路径无效")
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let uid = matchedUID.isEmpty ? generateUID() : matchedUID
        
        shareExtensionLogger.info("📝 [识别到新文件] 文件名: \(fileName) | UID: \(uid)")
        
        let keyVersion = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.keyVersion) ?? "default"
        let publicKey = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.publicKey)
        
        var encryptedPassword: String? = nil
        if !password.isEmpty, let publicKey = publicKey, !publicKey.isEmpty {
            encryptedPassword = ECIESEncryptor.shared.encrypt(data: password, publicKeyStr: publicKey)
            if encryptedPassword != nil {
                shareExtensionLogger.info("✅ [识别到新文件] 密码加密成功")
            } else {
                shareExtensionLogger.warning("⚠️ [识别到新文件] 密码加密失败，使用明文")
                encryptedPassword = password
            }
        } else if !password.isEmpty {
            shareExtensionLogger.warning("⚠️ [识别到新文件] 无公钥，使用明文密码")
            encryptedPassword = password
        }
        
        shareExtensionLogger.info("📝 [识别到新文件] 开始写入 WPPM 标记")
        let writeSuccess = writeWppmMarkers(tempURL: tempURL, uid: uid, encryptedPassword: encryptedPassword, keyVersion: keyVersion)
        shareExtensionLogger.info("📝 [识别到新文件] WPPM 标记写入结果: \(writeSuccess)")
        
        if writeSuccess {
            shareExtensionLogger.info("📝 [识别到新文件] 开始迁移到保险箱")
            let moveSuccess = moveToSafeVaultSync(tempURL: tempURL, newFileName: fileName)
            shareExtensionLogger.info("📝 [识别到新文件] 迁移结果: \(moveSuccess)")
            
            if moveSuccess {
                Task { @MainActor in
                    let owner = await self.queryOwnerForDoc(uid: uid, fileName: fileName)
                    shareExtensionLogger.info("📝 [识别到新文件] 开始保存数据库记录 | owner: \(owner, privacy: .public)")
                    let dbSuccess = AppGroupDBManager.shared.saveFileMapping(
                        fileName: fileName,
                        uid: uid,
                        passwordHash: password,
                        fileSize: fileSize,
                        isLocalVault: 1,
                        ownerAccount: owner
                    )
                    shareExtensionLogger.info("📝 [识别到新文件] 数据库保存结果: \(dbSuccess)")
                    
                    if dbSuccess {
                        shareExtensionLogger.info("✅ [识别到新文件] 所有步骤成功完成")
                        completeExtension()
                    } else {
                        shareExtensionLogger.error("❌ [识别到新文件] 数据库保存失败")
                        completeExtension(withError: "数据库保存失败")
                    }
                }
            } else {
                shareExtensionLogger.error("❌ [识别到新文件] 文件迁移失败")
                completeExtension(withError: "文件迁移失败")
            }
        } else {
            shareExtensionLogger.error("❌ [识别到新文件] WPPM 标记写入失败")
            completeExtension(withError: "写入标记失败")
        }
    }
    
    private func queryOwnerForDoc(uid: String, fileName: String) async -> String {
        shareExtensionLogger.info("🔍 [所属人查询] ===== 根据UID查询文档所属人 =====")
        shareExtensionLogger.info("🔍 [所属人查询] docId(UID): \(uid, privacy: .public) | fileName: \(fileName, privacy: .public)")
        
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            APIService.shared.fetchDocOwner(docId: uid, fileName: fileName) { result in
                switch result {
                case .success(let info):
                    shareExtensionLogger.info("✅ [所属人查询] 成功 | owner: \(info.ownerAccount, privacy: .public) | read: \(info.readAuth) | write: \(info.writeAuth)")
                    continuation.resume(returning: info.ownerAccount)
                case .failure(let error):
                    shareExtensionLogger.error("❌ [所属人查询] 失败: \(error.localizedDescription)，使用空owner")
                    continuation.resume(returning: "")
                }
            }
        }
    }
    
    private func confirmRename() {
        shareExtensionLogger.info("✅ [确认重命名] ===== confirmRename 开始 =====")
        shareExtensionLogger.info("✅ [确认重命名] 用户输入: newFileNameInput=\(newFileNameInput)")
        shareExtensionLogger.info("✅ [确认重命名] fileExtension=\(fileExtension)")
        
        let trimmedName = newFileNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        shareExtensionLogger.info("✅ [确认重命名] 去空格后: trimmedName=\(trimmedName)")
        
        if trimmedName.isEmpty {
            shareExtensionLogger.error("❌ [确认重命名] 文件名为空")
            verificationError = "文件名不能为空"
            return
        }
        
        let fullFileName = "\(trimmedName)\(fileExtension)"
        shareExtensionLogger.info("✅ [确认重命名] 完整文件名: fullFileName=\(fullFileName)")
        
        let existsInVault = fileNameExistsInVault(fileName: fullFileName)
        shareExtensionLogger.info("✅ [确认重命名] fileNameExistsInVault 返回: \(existsInVault)")
        
        if existsInVault {
            shareExtensionLogger.warning("⚠️ [确认重命名] 文件名已存在，阻止操作")
            verificationError = "文件名已存在，请输入其他名称"
            return
        }
        
        shareExtensionLogger.info("✅ [确认重命名] 文件名检查通过，继续执行")
        showRenameDialog = false
        verificationError = nil
        
        shareExtensionLogger.info("✅ [确认重命名] 调用 performSaveAsNew")
        performSaveAsNew(newFileName: fullFileName, password: isEncryptedFile ? capturedPassword : "")
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
                shareExtensionLogger.error("❌ [迁移同步] 目标文件已存在，拒绝覆盖: \(newFileName)")
                return false
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
        
        if isEncryptedFile {
            if capturedPassword.isEmpty {
                showPasswordInputDialog = true
                pendingAction = .syncOverride
                return
            }
            
            isVerifying = true
            
            OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
                Task { @MainActor in
                    self.isVerifying = false
                    
                    switch result {
                    case .success(let verified):
                        if verified {
                            self.performSyncOverride(fileName: fileName, uid: uid, password: self.capturedPassword)
                        } else {
                            self.showPasswordInputDialog = true
                            self.pendingAction = .syncOverride
                        }
                    case .failure(let error):
                        self.showPasswordInputDialog = true
                        self.pendingAction = .syncOverride
                    }
                }
            }
        } else {
            performSyncOverride(fileName: fileName, uid: uid, password: "")
        }
    }
    
    private func performSyncOverride(fileName: String, uid: String, password: String) {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        Task.detached {
            let keyVersion = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.keyVersion) ?? "default"
            let publicKey = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.publicKey)
            
            var encryptedPassword: String? = nil
            if !password.isEmpty, let publicKey = publicKey, !publicKey.isEmpty {
                encryptedPassword = ECIESEncryptor.shared.encrypt(data: password, publicKeyStr: publicKey)
                if encryptedPassword == nil {
                    encryptedPassword = password
                }
            } else if !password.isEmpty {
                encryptedPassword = password
            }
            
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, encryptedPassword: encryptedPassword, keyVersion: keyVersion)
            
            if success {
                let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: fileName, allowOverwrite: true)
                
                await MainActor.run {
                    if moveSuccess {
                        _ = AppGroupDBManager.shared.saveFileMapping(
                            fileName: fileName,
                            uid: uid,
                            passwordHash: password,
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
    
    private func verifyPasswordAndSaveAsNewFromBlueB() {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        if capturedPassword.isEmpty {
            verificationError = "请输入密码"
            return
        }
        
        isVerifying = true
        
        OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
            Task { @MainActor in
                self.isVerifying = false
                
                switch result {
                case .success(let verified):
                    if verified {
                        self.verificationError = nil
                        self.saveAsNewAction()
                    } else {
                        self.verificationError = "密码验证失败，请重试"
                    }
                case .failure(let error):
                    self.verificationError = error.localizedDescription
                }
            }
        }
    }
    
    private func saveAsNewAction() {
        shareExtensionLogger.info("➕ [另存为] ===== saveAsNewAction 开始 =====")
        shareExtensionLogger.info("➕ [另存为] detectedFileName: \(detectedFileName)")
        shareExtensionLogger.info("➕ [另存为] matchedAssetName: \(matchedAssetName)")
        shareExtensionLogger.info("➕ [另存为] matchedUID: \(matchedUID)")
        
        guard let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [另存为] tempFilePath 为空")
            completeExtension(withError: "文件路径无效")
            return
        }
        
        shareExtensionLogger.info("➕ [另存为] tempFilePath: \(tempURL.path)")
        
        let baseName = URL(fileURLWithPath: detectedFileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: detectedFileName).pathExtension.isEmpty ? "" : ".\(URL(fileURLWithPath: detectedFileName).pathExtension)"
        
        shareExtensionLogger.info("➕ [另存为] 提取文件名: baseName=\(baseName), ext=\(ext)")
        shareExtensionLogger.info("➕ [另存为] 默认新文件名: \(baseName)\(ext)")
        
        newFileNameInput = baseName
        fileExtension = ext
        showRenameDialog = true
        
        shareExtensionLogger.info("➕ [另存为] 显示重命名弹窗")
    }
    
    private func confirmSaveAsNew() {
        let trimmedName = newFileNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedName.isEmpty {
            verificationError = "文件名不能为空"
            return
        }
        
        if fileNameExistsInVault(fileName: trimmedName) {
            verificationError = "文件名已存在，请输入其他名称"
            return
        }
        
        if isEncryptedFile {
            if capturedPassword.isEmpty {
                showPasswordInputDialog = true
                pendingAction = .saveAsNew(newFileName: trimmedName)
                return
            }
            
            guard let tempURL = tempFilePath else {
                completeExtension(withError: "文件路径无效")
                return
            }
            
            isVerifying = true
            
            OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
                Task { @MainActor in
                    self.isVerifying = false
                    
                    switch result {
                    case .success(let verified):
                        if verified {
                            self.showRenameDialog = false
                            self.verificationError = nil
                            self.performSaveAsNew(newFileName: trimmedName, password: self.capturedPassword)
                        } else {
                            self.showPasswordInputDialog = true
                            self.pendingAction = .saveAsNew(newFileName: trimmedName)
                        }
                    case .failure(let error):
                        self.showPasswordInputDialog = true
                        self.pendingAction = .saveAsNew(newFileName: trimmedName)
                    }
                }
            }
        } else {
            showRenameDialog = false
            verificationError = nil
            performSaveAsNew(newFileName: trimmedName, password: "")
        }
    }
    
    private func performSaveAsNew(newFileName: String, password: String? = nil) {
        shareExtensionLogger.info("➕ [执行另存为] ===== performSaveAsNew 开始 =====")
        shareExtensionLogger.info("➕ [执行另存为] 目标文件名: \(newFileName)")
        shareExtensionLogger.info("➕ [执行另存为] 密码参数: \(password != nil ? "有" : "无")")
        shareExtensionLogger.info("➕ [执行另存为] capturedPassword: \(capturedPassword)")
        
        guard let tempURL = tempFilePath else {
            shareExtensionLogger.error("❌ [执行另存为] tempFilePath 为空")
            completeExtension(withError: "文件路径无效")
            return
        }
        
        shareExtensionLogger.info("➕ [执行另存为] tempFilePath: \(tempURL.path)")
        
        // 另存为新文件：优先复用文件尾部原有UID，没有再生成新UID
        let fileOwnUid = ZipExtraFieldManager.shared.readUid(from: tempURL)
        shareExtensionLogger.info("➕ [执行另存为] 文件尾部原有UID: \(fileOwnUid ?? "无")")
        
        let uid = fileOwnUid ?? generateUID()
        shareExtensionLogger.info("➕ [执行另存为] 最终使用UID: \(uid)")
        
        let finalPassword = password ?? capturedPassword
        shareExtensionLogger.info("➕ [执行另存为] 最终使用密码: \(finalPassword.prefix(8))...")
        
        shareExtensionLogger.info("➕ [执行另存为] 新文件名: \(newFileName) | UID: \(uid)")
        
        Task.detached {
            let keyVersion = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.keyVersion) ?? "default"
            let publicKey = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.publicKey)
            
            var encryptedPassword: String? = nil
            if !finalPassword.isEmpty, let publicKey = publicKey, !publicKey.isEmpty {
                encryptedPassword = ECIESEncryptor.shared.encrypt(data: finalPassword, publicKeyStr: publicKey)
                if encryptedPassword == nil {
                    encryptedPassword = finalPassword
                }
            } else if !finalPassword.isEmpty {
                encryptedPassword = finalPassword
            }
            
            shareExtensionLogger.info("➕ [执行另存为] 开始写入 WPPM 标记")
            let success = writeWppmMarkers(tempURL: tempURL, uid: uid, encryptedPassword: encryptedPassword, keyVersion: keyVersion)
            shareExtensionLogger.info("➕ [执行另存为] WPPM 标记写入结果: \(success)")
            
            if success {
                shareExtensionLogger.info("➕ [执行另存为] 开始迁移文件到保险箱")
                let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: newFileName)
                shareExtensionLogger.info("➕ [执行另存为] 文件迁移结果: \(moveSuccess)")
                
                await MainActor.run {
                    if moveSuccess {
                        Task { @MainActor in
                            let owner = await self.queryOwnerForDoc(uid: uid, fileName: newFileName)
                            // 另存为新文件：直接插入新记录，不触发 update（避免覆盖原文件记录）
                            let insertSuccess = AppGroupDBManager.shared.insertRecord(
                                uid: uid,
                                fileName: newFileName,
                                passwordHash: capturedPassword,
                                fileSize: fileSize,
                                isLocalVault: 1,
                                ownerAccount: owner
                            )
                            shareExtensionLogger.info("➕ [执行另存为] 数据库插入结果: \(insertSuccess) | owner: \(owner, privacy: .public)")
                            shareExtensionLogger.info("✅ [另存为新文件] 成功")
                            completeExtension()
                        }
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
    
    private func verifyAndShowAssetSelectionFromBlueA() {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        if capturedPassword.isEmpty {
            showPasswordInputDialog = true
            pendingAction = .associateOverride
            return
        }
        
        isVerifying = true
        
        OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: capturedPassword) { result in
            Task { @MainActor in
                self.isVerifying = false
                
                switch result {
                case .success(let verified):
                    if verified {
                        self.showAssetSelection()
                    } else {
                        self.showPasswordInputDialog = true
                        self.pendingAction = .associateOverride
                    }
                case .failure(let error):
                    self.showPasswordInputDialog = true
                    self.pendingAction = .associateOverride
                }
            }
        }
    }
    
    private func showAssetSelection() {
        previousState = actionState
        assetList = AppGroupDBManager.shared.queryAllLocalVaultRecords()
        actionState = .stateD
    }
    
    private func selectAsset(record: FileMappingRecord) {
        guard let tempURL = tempFilePath else {
            completeExtension(withError: "文件路径无效")
            return
        }
        
        let fileName = record.file_name
        let password = isEncryptedFile ? capturedPassword : ""
        
        let targetUid = readUidFromVaultFile(fileName: fileName) ?? record.uid
        
        shareExtensionLogger.info("🎯 [状态D] 选择资产: \(fileName) | UID(数据库): \(record.uid) | UID(文件尾部): \(targetUid)")
        shareExtensionLogger.info("🎯 [状态D] 文件加密状态: \(isEncryptedFile ? "已加密" : "未加密")")
        
        if isEncryptedFile {
            isVerifying = true
            
            OfficeCryptoVerifier.shared.verifyPasswordAsync(fileURL: tempURL, password: password) { result in
                Task { @MainActor in
                    self.isVerifying = false
                    
                    switch result {
                    case .success(let verified):
                        if verified {
                            Task.detached {
                                let keyVersion = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.keyVersion) ?? "default"
                                let publicKey = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.publicKey)
                                
                                var encryptedPassword: String? = nil
                                if !password.isEmpty, let publicKey = publicKey, !publicKey.isEmpty {
                                    encryptedPassword = ECIESEncryptor.shared.encrypt(data: password, publicKeyStr: publicKey)
                                    if encryptedPassword == nil {
                                        encryptedPassword = password
                                    }
                                } else if !password.isEmpty {
                                    encryptedPassword = password
                                }
                                
                                let success = writeWppmMarkers(tempURL: tempURL, uid: targetUid, encryptedPassword: encryptedPassword, keyVersion: keyVersion)
                                
                                if success {
                                    let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: fileName, allowOverwrite: true)
                                    
                                    await MainActor.run {
                                        if moveSuccess {
                                            _ = AppGroupDBManager.shared.saveFileMapping(
                                                fileName: fileName,
                                                uid: targetUid,
                                                passwordHash: password,
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
                        } else {
                            self.showPasswordInputDialog = true
                            self.pendingAction = .associateOverride
                        }
                    case .failure(let error):
                        self.showPasswordInputDialog = true
                        self.pendingAction = .associateOverride
                    }
                }
            }
        } else {
            Task.detached {
                let keyVersion = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.keyVersion) ?? "default"
                let success = writeWppmMarkers(tempURL: tempURL, uid: targetUid, encryptedPassword: nil, keyVersion: keyVersion)
                
                if success {
                    let moveSuccess = await moveToSafeVault(tempURL: tempURL, newFileName: fileName, allowOverwrite: true)
                    
                    await MainActor.run {
                        if moveSuccess {
                            _ = AppGroupDBManager.shared.saveFileMapping(
                                fileName: fileName,
                                uid: targetUid,
                                passwordHash: password,
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
    }
    
    private func readUidFromVaultFile(fileName: String) -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        let fileURL = vaultDir.appendingPathComponent(fileName)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let uid = ZipExtraFieldManager.shared.readUid(from: fileURL)
            shareExtensionLogger.info("📖 [状态D] 从文件尾部读取UID: \(uid ?? "nil")")
            return uid
        }
        
        return nil
    }
    
    private func goBack() {
        actionState = previousState
    }
    
    private func generateUID() -> String {
        return UidGenerator.shared.createUid()
    }
    
    private nonisolated func writeWppmMarkers(tempURL: URL, uid: String, encryptedPassword: String?, keyVersion: String) -> Bool {
        return ZipExtraFieldManager.shared.writeMetadata(
            to: tempURL,
            uid: uid,
            password: encryptedPassword,
            keyVersion: keyVersion
        )
    }
    
    private func moveToSafeVault(tempURL: URL, newFileName: String, allowOverwrite: Bool = false) async -> Bool {
        shareExtensionLogger.info("📦 [迁移] ===== moveToSafeVault 开始 =====")
        shareExtensionLogger.info("📦 [迁移] 源文件路径: \(tempURL.path)")
        shareExtensionLogger.info("📦 [迁移] 目标文件名: \(newFileName)")
        shareExtensionLogger.info("📦 [迁移] 是否允许覆盖: \(allowOverwrite)")
        
        do {
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            ) else {
                shareExtensionLogger.error("❌ [迁移] 无法获取App Group容器，appGroupID=\(appGroupID)")
                return false
            }
            
            shareExtensionLogger.info("📦 [迁移] App Group容器路径: \(containerURL.path)")
            
            let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
            shareExtensionLogger.info("📦 [迁移] 保险箱目录路径: \(vaultDir.path)")
            
            try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
            shareExtensionLogger.info("📦 [迁移] 保险箱目录创建/确认成功")
            
            var destURL = vaultDir.appendingPathComponent(newFileName)
            shareExtensionLogger.info("📦 [迁移] 目标文件完整路径: \(destURL.path)")
            
            let fileExists = FileManager.default.fileExists(atPath: destURL.path)
            shareExtensionLogger.info("📦 [迁移] 目标文件是否已存在: \(fileExists)")
            
            if fileExists {
                if allowOverwrite {
                    shareExtensionLogger.info("📦 [迁移] 目标文件已存在，执行覆盖操作")
                    try FileManager.default.removeItem(at: destURL)
                    shareExtensionLogger.info("✅ [迁移] 已删除旧文件")
                } else {
                    shareExtensionLogger.error("❌ [迁移] 目标文件已存在，拒绝覆盖: \(newFileName)")
                    return false
                }
            }
            
            shareExtensionLogger.info("📦 [迁移] 开始文件协调和移动操作")
            
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

struct InputField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let keyboardType: UIKeyboardType
    let errorMessage: String
    
    init(label: String, placeholder: String, text: Binding<String>, isSecure: Bool = false, keyboardType: UIKeyboardType = .default, errorMessage: String = "") {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.keyboardType = keyboardType
        self.errorMessage = errorMessage
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.body)
                    .foregroundColor(.white)
                    .frame(width: 60, alignment: .leading)
                
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .padding()
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .padding()
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(8)
                }
            }
            
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
    }
}