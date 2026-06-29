import Foundation
import OSLog

let apiLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "APIService")

struct AuthBootstrapResult {
    let isAuthenticated: Bool
    let tokenRefreshed: Bool
    let keyUpdated: Bool
}

struct DocOwnerInfo {
    let ownerAccount: String
    let ownerName: String
    let readAuth: Bool
    let writeAuth: Bool

    var hasAnyAuth: Bool {
        return readAuth || writeAuth
    }
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
    
    func logout(completion: @escaping (Result<String, Error>) -> Void) {
        apiLogger.info("🔓 [API] 用户注销开始")

        let token = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.token) ?? ""

        let clearLocalToken = {
            _ = AppGroupDBManager.shared.setConfigValue(key: GlobalConfigKey.token, value: "")
        }

        if token.isEmpty {
            apiLogger.info("ℹ️ [API] 本地无token，跳过远程登出")
            clearLocalToken()
            DispatchQueue.main.async {
                completion(.success("登出成功"))
            }
            return
        }

        guard self.configureNetworkIfNeeded() else {
            apiLogger.warning("⚠️ [API] 未配置域名，跳过远程登出，仅清空本地token")
            clearLocalToken()
            DispatchQueue.main.async {
                completion(.success("登出成功"))
            }
            return
        }

        NetworkClient.shared.logout(token: token) { result in
            clearLocalToken()
            switch result {
            case .success(let message):
                apiLogger.info("✅ [API] 远程登出成功 | message: \(message)")
            case .failure(let error):
                apiLogger.error("❌ [API] 远程登出失败: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
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

    func fetchDocOwner(docId: String, fileName: String?, completion: @escaping (Result<DocOwnerInfo, Error>) -> Void) {
        let token = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.token) ?? ""
        guard !token.isEmpty else {
            apiLogger.error("❌ [API] 文档所属人：token为空")
            completion(.failure(NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "未登录，无法查询文档所属人"])))
            return
        }

        guard self.configureNetworkIfNeeded() else {
            apiLogger.error("❌ [API] 文档所属人：未配置域名")
            completion(.failure(NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器未配置"])))
            return
        }

        apiLogger.info("🔍 [API] 开始查询文档所属人 | docId: \(docId, privacy: .public) | fileName: \(fileName ?? "", privacy: .public)")

        NetworkClient.shared.docOwner(token: token, docId: docId, fileName: fileName) { result in
            switch result {
            case .success(let data):
                let ownerAccount = data.ownerAccount ?? ""
                let ownerName = data.ownerName ?? ""
                let info = DocOwnerInfo(
                    ownerAccount: ownerAccount,
                    ownerName: ownerName,
                    readAuth: data.readAuth,
                    writeAuth: data.writeAuth
                )
                apiLogger.info("✅ [API] 文档所属人查询成功 | owner: \(ownerAccount, privacy: .public) | read: \(data.readAuth) | write: \(data.writeAuth)")
                completion(.success(info))
            case .failure(let error):
                apiLogger.error("❌ [API] 文档所属人查询失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }
    
    func fetchDocPassword(docId: String, encryPassword: String, isTemp: Bool = false, customKeyVersion: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let token = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.token) ?? ""
        guard !token.isEmpty else {
            apiLogger.error("❌ [API] 获取文档密码：token为空")
            completion(.failure(NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "未登录，无法获取文档密码"])))
            return
        }

        guard self.configureNetworkIfNeeded() else {
            apiLogger.error("❌ [API] 获取文档密码：未配置域名")
            completion(.failure(NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "服务器未配置"])))
            return
        }

        let keyVersion = customKeyVersion ?? AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.keyVersion)
        
        apiLogger.info("🔍 [API] 开始获取文档密码 | docId: \(docId, privacy: .public) | keyVersion: \(keyVersion ?? "default") | isTemp: \(isTemp)")

        NetworkClient.shared.docPassword(token: token, docId: docId, encryPassword: encryPassword, keyVersion: keyVersion, isTemp: isTemp) { result in
            switch result {
            case .success(let data):
                apiLogger.info("✅ [API] 文档密码获取成功")
                completion(.success(data.password))
            case .failure(let error):
                apiLogger.error("❌ [API] 文档密码获取失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }
}
