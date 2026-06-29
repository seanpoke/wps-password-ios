import Foundation
import OSLog

let networkLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "Network")

enum API {
    case login(account: String, password: String)
    case refreshToken(token: String)
    case latestKey
    case logout(token: String)
    case docOwner(token: String, docId: String, fileName: String?)
    case docPassword(token: String, docId: String, encryPassword: String, keyVersion: String?, isTemp: Bool?)
}

extension API {
    var path: String {
        switch self {
        case .login:
            return "/account/login"
        case .refreshToken:
            return "/account/refresh-token"
        case .latestKey:
            return "/config/latest-key"
        case .logout:
            return "/account/logout"
        case .docOwner:
            return "/doc/owner"
        case .docPassword:
            return "/doc/password"
        }
    }
    
    var method: String {
        switch self {
        case .login, .refreshToken, .logout, .docOwner, .docPassword:
            return "POST"
        case .latestKey:
            return "GET"
        }
    }
    
    var headers: [String: String] {
        var headers = ["Content-Type": "application/json"]
        switch self {
        case .refreshToken(let token), .logout(let token):
            headers["token"] = token
        case .docOwner(let token, _, _):
            headers["token"] = token
        case .docPassword(let token, _, _, _, _):
            headers["token"] = token
        default:
            break
        }
        return headers
    }
    
    var body: Data? {
        do {
            switch self {
            case .login(let account, let password):
                let params: [String: Any] = [
                    "account": account,
                    "password": password
                ]
                return try JSONSerialization.data(withJSONObject: params)
            case .refreshToken, .latestKey, .logout:
                return nil
            case .docOwner(_, let docId, let fileName):
                var params: [String: Any] = [
                    "docId": docId
                ]
                if let fileName = fileName, !fileName.isEmpty {
                    params["fileName"] = fileName
                }
                return try JSONSerialization.data(withJSONObject: params)
            case .docPassword(_, let docId, let encryPassword, let keyVersion, let isTemp):
                var params: [String: Any] = [
                    "docId": docId,
                    "encryPassword": encryPassword
                ]
                if let keyVersion = keyVersion, !keyVersion.isEmpty {
                    params["keyVersion"] = keyVersion
                }
                if let isTemp = isTemp {
                    params["isTemp"] = isTemp
                }
                return try JSONSerialization.data(withJSONObject: params)
            }
        } catch {
            networkLogger.error("❌ [Network] 请求体序列化失败: \(error)")
            return nil
        }
    }
}

struct APIResponse<T: Codable>: Codable {
    let message: String
    let status: Int
    let data: T?
}

struct LoginResponseData: Codable {
    let token: String
    let account: String
    let name: String
    let role: String
}

struct RefreshTokenResponseData: Codable {
    let token: String
    let account: String
    let name: String
    let role: String
}

struct LatestKeyResponseData: Codable {
    let keyVersion: String
    let publicKey: String
}

struct DocOwnerResponseData: Codable {
    let ownerAccount: String?
    let ownerName: String?
    let readAuth: Bool
    let writeAuth: Bool
}

struct DocPasswordResponseData: Codable {
    let password: String
}

final class NetworkClient: NSObject, URLSessionDelegate {
    static let shared = NetworkClient()
    
    private var baseURL: String = ""
    private let timeoutInterval: TimeInterval = 30
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {}
    
    func configure(baseURL: String) {
        self.baseURL = baseURL
        networkLogger.info("✅ [Network] 网络客户端已配置 | baseURL: \(baseURL, privacy: .public)")
    }
    
    func configureIfNeeded(baseURL: String) {
        guard self.baseURL.isEmpty else {
            networkLogger.info("ℹ️ [Network] 网络客户端已配置，跳过重复配置")
            return
        }
        configure(baseURL: baseURL)
    }
    
    func buildBaseURL(domain: String, port: String) -> String {
        var baseURL = domain
        if !baseURL.hasPrefix("http") {
            baseURL = "https://" + baseURL
        }
        if !port.isEmpty {
            if let url = URL(string: baseURL), url.port == nil {
                baseURL += ":\(port)"
            }
        }
        return baseURL
    }
    
    func request<T: Codable>(api: API, completion: @escaping (Result<T, Error>) -> Void) {
        guard !baseURL.isEmpty else {
            completion(.failure(NetworkError.invalidBaseURL))
            return
        }
        
        guard let url = URL(string: baseURL + api.path) else {
            networkLogger.error("❌ [Network] 无效的URL: \(self.baseURL + api.path, privacy: .public)")
            completion(.failure(NetworkError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = api.method
        request.allHTTPHeaderFields = api.headers
        request.httpBody = api.body
        request.timeoutInterval = timeoutInterval
        
        networkLogger.info("🔄 [Network] 发起请求 | \(api.method) \(api.path)")
        
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            networkLogger.info("📤 [Network] 请求体(入参): \(bodyString, privacy: .public)")
        } else {
            networkLogger.info("📤 [Network] 请求体(入参): 无")
        }
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                networkLogger.error("❌ [Network] 请求失败: \(error)")
                completion(.failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                networkLogger.error("❌ [Network] 无效的HTTP响应")
                completion(.failure(NetworkError.invalidResponse))
                return
            }
            
            networkLogger.info("📤 [Network] 收到响应 | 状态码: \(httpResponse.statusCode)")
            
            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                networkLogger.info("📥 [Network] 响应体(出参): \(responseString, privacy: .public)")
            } else {
                networkLogger.info("📥 [Network] 响应体(出参): 无")
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = self.parseErrorMessage(data: data)
                networkLogger.error("❌ [Network] 服务端错误 | 状态码: \(httpResponse.statusCode) | 消息: \(errorMessage, privacy: .public)")
                completion(.failure(NetworkError.serverError(code: httpResponse.statusCode, message: errorMessage)))
                return
            }
            
            guard let data = data else {
                networkLogger.error("❌ [Network] 响应数据为空")
                completion(.failure(NetworkError.emptyData))
                return
            }
            
            do {
                let apiResponse = try JSONDecoder().decode(APIResponse<T>.self, from: data)
                
                guard (200...299).contains(apiResponse.status) else {
                    networkLogger.error("❌ [Network] 业务状态码异常 | status: \(apiResponse.status) | message: \(apiResponse.message, privacy: .public)")
                    completion(.failure(NetworkError.serverError(code: apiResponse.status, message: apiResponse.message)))
                    return
                }
                
                if let data = apiResponse.data {
                    networkLogger.info("✅ [Network] 请求成功 | \(api.path)")
                    completion(.success(data))
                } else {
                    networkLogger.warning("⚠️ [Network] 响应数据为nil")
                    completion(.failure(NetworkError.emptyData))
                }
            } catch {
                networkLogger.error("❌ [Network] 响应解析失败: \(error)")
                completion(.failure(NetworkError.parseError(error)))
            }
        }
        
        task.resume()
    }
    
    private func parseErrorMessage(data: Data?) -> String {
        guard let data = data else { return "未知错误" }
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let message = json["message"] as? String {
                return message
            }
        } catch {
            networkLogger.debug("❌ [Network] 错误消息解析失败: \(error)")
        }
        return "未知错误"
    }
    
    func login(account: String, password: String, completion: @escaping (Result<LoginResponseData, Error>) -> Void) {
        request(api: .login(account: account, password: password), completion: completion)
    }
    
    func refreshToken(token: String, completion: @escaping (Result<RefreshTokenResponseData, Error>) -> Void) {
        request(api: .refreshToken(token: token), completion: completion)
    }
    
    func fetchLatestKey(completion: @escaping (Result<LatestKeyResponseData, Error>) -> Void) {
        request(api: .latestKey, completion: completion)
    }

    func logout(token: String, completion: @escaping (Result<String, Error>) -> Void) {
        request(api: .logout(token: token), completion: completion)
    }
    
    func docOwner(token: String, docId: String, fileName: String?, completion: @escaping (Result<DocOwnerResponseData, Error>) -> Void) {
        request(api: .docOwner(token: token, docId: docId, fileName: fileName), completion: completion)
    }
    
    func docPassword(token: String, docId: String, encryPassword: String, keyVersion: String?, isTemp: Bool?, completion: @escaping (Result<DocPasswordResponseData, Error>) -> Void) {
        request(api: .docPassword(token: token, docId: docId, encryPassword: encryPassword, keyVersion: keyVersion, isTemp: isTemp), completion: completion)
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

enum NetworkError: Error, LocalizedError {
    case invalidBaseURL
    case invalidURL
    case invalidResponse
    case emptyData
    case serverError(code: Int, message: String)
    case parseError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "基础URL未配置"
        case .invalidURL:
            return "无效的URL"
        case .invalidResponse:
            return "无效的HTTP响应"
        case .emptyData:
            return "响应数据为空"
        case .serverError(_, let message):
            return message
        case .parseError(let error):
            return "数据解析失败: \(error.localizedDescription)"
        }
    }
}
