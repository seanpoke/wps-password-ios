import Foundation
import OSLog

let apiLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "APIService")

struct AuthBootstrapResult {
    let isAuthenticated: Bool
    let tokenRefreshed: Bool
    let keyUpdated: Bool
}

final class APIService {
    
    static let shared = APIService()
    
    private init() {}
    
    func bootstrap(completion: @escaping (Result<AuthBootstrapResult, Error>) -> Void) {
        apiLogger.info("🔐 [API] 启动认证初始化流程")
        
        let domain = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.domain) ?? ""
        guard !domain.isEmpty else {
            apiLogger.info("🌐 [API] 未配置域名，跳过认证流程")
            completion(.success(AuthBootstrapResult(isAuthenticated: false, tokenRefreshed: false, keyUpdated: false)))
            return
        }
        
        let port = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.port) ?? ""
        let baseURL = NetworkClient.shared.buildBaseURL(domain: domain, port: port)
        NetworkClient.shared.configureIfNeeded(baseURL: baseURL)
        
        let token = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.token) ?? ""
        let hasToken = !token.isEmpty
        
        let group = DispatchGroup()
        var tokenRefreshed = false
        var keyUpdated = false
        var authError: Error?
        var keyError: Error?
        
        if hasToken {
            group.enter()
            NetworkClient.shared.refreshToken(token: token) { result in
                defer { group.leave() }
                switch result {
                case .success(let data):
                    apiLogger.info("✅ [API] Token刷新成功 | account: \(data.account)")
                    _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.token, value: data.token)
                    _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.name, value: data.name)
                    _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.role, value: data.role)
                    _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.account, value: data.account)
                    tokenRefreshed = true
                case .failure(let error):
                    apiLogger.error("❌ [API] Token刷新失败: \(error.localizedDescription)")
                    authError = error
                }
            }
        }
        
        group.enter()
        NetworkClient.shared.fetchLatestKey { result in
            defer { group.leave() }
            switch result {
            case .success(let data):
                apiLogger.info("✅ [API] 最新密钥获取成功 | keyVersion: \(data.keyVersion)")
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.keyVersion, value: data.keyVersion)
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.publicKey, value: data.publicKey)
                keyUpdated = true
            case .failure(let error):
                apiLogger.error("❌ [API] 最新密钥获取失败: \(error.localizedDescription)")
                keyError = error
            }
        }
        
        group.notify(queue: .main) {
            if hasToken {
                if let authError = authError {
                    apiLogger.error("❌ [API] 认证失败，仅清空token")
                    _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.token, value: "")
                    completion(.failure(authError))
                    return
                }
                
                let isAuthenticated = tokenRefreshed
                apiLogger.info("🔐 [API] 认证初始化完成 | 已认证: \(isAuthenticated) | 密钥更新: \(keyUpdated)")
                completion(.success(AuthBootstrapResult(
                    isAuthenticated: isAuthenticated,
                    tokenRefreshed: tokenRefreshed,
                    keyUpdated: keyUpdated
                )))
            } else {
                if let keyError = keyError {
                    apiLogger.warning("⚠️ [API] 未登录且密钥获取失败: \(keyError.localizedDescription)")
                }
                apiLogger.info("🔐 [API] 认证初始化完成 | 未登录 | 密钥更新: \(keyUpdated)")
                completion(.success(AuthBootstrapResult(
                    isAuthenticated: false,
                    tokenRefreshed: false,
                    keyUpdated: keyUpdated
                )))
            }
        }
    }
    
    func login(account: String, password: String, domain: String, port: String, rememberPassword: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let baseURL = NetworkClient.shared.buildBaseURL(domain: domain, port: port)
        NetworkClient.shared.configure(baseURL: baseURL)
        
        _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.domain, value: domain)
        _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.port, value: port)
        _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.rememberPassword, value: rememberPassword ? "true" : "false")
        
        NetworkClient.shared.login(account: account, password: password) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                apiLogger.info("✅ [API] 登录成功 | account: \(data.account)")
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.token, value: data.token)
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.name, value: data.name)
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.role, value: data.role)
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.account, value: data.account)
                
                if rememberPassword {
                    _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.password, value: password)
                } else {
                    _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.password, value: "")
                }
                
                self.fetchAndSaveLatestKey { keyResult in
                    switch keyResult {
                    case .success:
                        apiLogger.info("✅ [API] 登录后密钥获取成功")
                    case .failure(let error):
                        apiLogger.error("❌ [API] 登录后密钥获取失败: \(error.localizedDescription)")
                    }
                    DispatchQueue.main.async {
                        completion(.success(()))
                    }
                }
                
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func fetchAndSaveLatestKey(completion: @escaping (Result<Void, Error>) -> Void) {
        NetworkClient.shared.fetchLatestKey { result in
            switch result {
            case .success(let data):
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.keyVersion, value: data.keyVersion)
                _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.publicKey, value: data.publicKey)
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func logout() {
        apiLogger.info("🔓 [API] 用户注销")
        _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.token, value: "")
    }
    
    func logoutAndClearAll() {
        apiLogger.info("🔓 [API] 用户注销并清空所有配置")
        _ = AppGroupDBManager.shared.clearAllConfig()
    }
    
    func isAuthenticated() -> Bool {
        guard let token = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.token),
              !token.isEmpty else {
            return false
        }
        return true
    }
    
    func configureNetworkIfNeeded() -> Bool {
        let domain = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.domain) ?? ""
        guard !domain.isEmpty else {
            return false
        }
        let port = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.port) ?? ""
        let baseURL = NetworkClient.shared.buildBaseURL(domain: domain, port: port)
        NetworkClient.shared.configureIfNeeded(baseURL: baseURL)
        return true
    }
}
