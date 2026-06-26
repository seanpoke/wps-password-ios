import SwiftUI
import OSLog

struct LoginView: View {
    @State private var account = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var port = ""
    @State private var rememberPassword = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var domainError = ""
    
    var onLoginSuccess: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 60)
                    
                    VStack(spacing: 24) {
                        VStack(spacing: 16) {
                            InputField(
                                label: "账号",
                                placeholder: "请输入账号",
                                text: $account,
                                keyboardType: .emailAddress
                            )
                            
                            InputField(
                                label: "密码",
                                placeholder: "请输入密码",
                                text: $password,
                                isSecure: true
                            )
                            
                            InputField(
                                label: "域名",
                                placeholder: "请输入服务器域名或IP",
                                text: $domain,
                                errorMessage: domainError
                            )
                            .onChange(of: domain) {
                                validateDomain()
                            }
                            
                            InputField(
                                label: "端口",
                                placeholder: "请输入端口号",
                                text: $port,
                                keyboardType: .numberPad
                            )
                            
                            HStack(spacing: 8) {
                                Button(action: {
                                    rememberPassword.toggle()
                                }) {
                                    Image(systemName: rememberPassword ? "checkmark.square.fill" : "square")
                                        .foregroundColor(rememberPassword ? .blue : .gray)
                                        .font(.system(size: 20))
                                }
                                
                                Text("记住密码")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                            }
                        }
                        
                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        
                        Button(action: performLogin) {
                            if isLoading {
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
                        .disabled(isLoading || !isFormValid)
                        .opacity(isLoading || !isFormValid ? 0.6 : 1.0)
                    }
                    .padding()
                    
                    Spacer(minLength: 60)
                }
                .frame(maxHeight: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    EmptyView()
                }
            }
            .onAppear {
                loadSavedCredentials()
            }
        }
    }
    
    private var isFormValid: Bool {
        !account.isEmpty && !password.isEmpty && !domain.isEmpty && domainError.isEmpty
    }
    
    private func validateDomain() {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedDomain.isEmpty {
            domainError = ""
            return
        }
        
        if trimmedDomain.hasPrefix("http://") {
            domainError = "仅支持HTTPS协议"
            return
        }
        
        if trimmedDomain.hasPrefix("https://") {
            domainError = ""
            return
        }
        
        domainError = ""
    }
    
    private func normalizeDomain() -> String {
        var normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        
        if normalized.hasPrefix("http://") {
            normalized = normalized.replacingOccurrences(of: "http://", with: "https://")
        }
        
        return normalized
    }
    
    private func buildBaseURL() -> String {
        let normalizedDomain = normalizeDomain()
        
        if let portNumber = Int(port), portNumber > 0 {
            if let url = URL(string: normalizedDomain) {
                return "\(url.scheme ?? "https")://\(url.host ?? ""):\(portNumber)"
            }
        }
        
        return normalizedDomain
    }
    
    private func performLogin() {
        guard isFormValid else {
            errorMessage = "请填写完整的登录信息"
            return
        }
        
        isLoading = true
        errorMessage = ""
        
        let normalizedDomain = normalizeDomain()
        
        APIService.shared.login(account: account, password: password, domain: normalizedDomain, port: port, rememberPassword: rememberPassword) { result in
            DispatchQueue.main.async {
                isLoading = false
                
                switch result {
                case .success:
                    appLogger.info("✅ [Login] 登录成功")
                    self.onLoginSuccess()
                    
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    appLogger.error("❌ [Login] 登录失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func loadSavedCredentials() {
        let savedAccount = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.account) ?? ""
        let savedPassword = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.password) ?? ""
        let savedDomain = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.domain) ?? ""
        let savedPort = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.port) ?? ""
        let savedRememberPassword = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.rememberPassword) ?? "false"

        self.rememberPassword = savedRememberPassword == "true"

        if rememberPassword {
            self.account = savedAccount
            self.password = savedPassword
        } else {
            self.account = savedAccount
        }
        self.domain = savedDomain
        self.port = savedPort
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
                    .foregroundColor(.primary)
                    .frame(width: 60, alignment: .leading)
                
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboardType)
                        .padding()
                        .background(Color(.secondarySystemBackground))
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

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView(onLoginSuccess: {})
    }
}
