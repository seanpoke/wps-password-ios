import Foundation
import OSLog
import CommonCrypto

let cryptoLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "OfficeCrypto")

enum CryptoError: Error, Equatable {
    case fileNotFound
    case fileTooLarge
    case invalidFormat
    case decryptionFailed
    case timeout
    case cancelled
    case internalError(String)
    case invalidPassword
    case unsupportedEncryptionType(String)
    
    var localizedDescription: String {
        switch self {
        case .fileNotFound:
            return "文件不存在"
        case .fileTooLarge:
            return "文件过大"
        case .invalidFormat:
            return "无效的文件格式"
        case .decryptionFailed:
            return "解密失败"
        case .timeout:
            return "验证超时"
        case .cancelled:
            return "操作已取消"
        case .internalError(let message):
            return "内部错误: \(message)"
        case .invalidPassword:
            return "密码不正确"
        case .unsupportedEncryptionType(let type):
            return "不支持的加密类型: \(type)"
        }
    }
}

final class OfficeCryptoVerifier {
    
    static let shared = OfficeCryptoVerifier()
    
    private let maxFileSize = 500 * 1024 * 1024
    private let timeoutForSmallFile: TimeInterval = 15
    private let timeoutForLargeFile: TimeInterval = 30
    private let bufferSize = 8 * 1024 * 1024
    
    private init() {}
    
    func verifyPasswordAsync(fileURL: URL, password: String, timeout: TimeInterval? = nil, completion: @escaping (Result<Bool, CryptoError>) -> Void) {
        cryptoLogger.info("🔐 [密码验证] 收到验证请求，密码: \(password)，长度: \(password.count)")
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            DispatchQueue.main.async {
                completion(.failure(.fileNotFound))
            }
            return
        }
        
        do {
            let fileSize = try fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
            if fileSize > Int64(maxFileSize) {
                DispatchQueue.main.async {
                    completion(.failure(.fileTooLarge))
                }
                return
            }
            
            let actualTimeout = timeout ?? (fileSize <= 100 * 1024 * 1024 ? timeoutForSmallFile : timeoutForLargeFile)
            
            var completed = false
            let completionLock = NSLock()
            
            let safeCompletion: (Result<Bool, CryptoError>) -> Void = { result in
                completionLock.lock()
                defer { completionLock.unlock() }
                guard !completed else {
                    cryptoLogger.warning("⚠️ [密码验证] 回调已被调用，忽略重复调用")
                    return
                }
                completed = true
                DispatchQueue.main.async {
                    completion(result)
                }
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + actualTimeout) {
                safeCompletion(.failure(.timeout))
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.performOfficePasswordVerification(fileURL: fileURL, password: password)
                safeCompletion(result)
            }
            
        } catch {
            DispatchQueue.main.async {
                completion(.failure(.internalError(error.localizedDescription)))
            }
        }
    }
    
    private func performOfficePasswordVerification(fileURL: URL, password: String) -> Result<Bool, CryptoError> {
        cryptoLogger.info("🔐 [密码验证] 开始验证 Office 文件密码")
        
        do {
            let fileData = try Data(contentsOf: fileURL, options: .uncached)
            cryptoLogger.debug("🔐 [密码验证] 文件大小: \(fileData.count) 字节")
            
            // 分析文件结构
            analyzeFileStructure(data: fileData)
            
            // 检查是否为 OLE2 复合文档格式（旧版 Office 加密）
            if isOLE2Format(data: fileData) {
                cryptoLogger.info("🔐 [密码验证] 识别为 OLE2 复合文档格式")
                return verifyOLE2Password(data: fileData, password: password)
            }
            
            // 检查是否为加密的 OOXML 文件
            guard let encryptedPackageStart = fileData.range(of: "EncryptedPackage".data(using: .utf8)!) else {
                cryptoLogger.debug("🔐 [密码验证] 文件中未找到 EncryptedPackage 标记")
                
                // 尝试用简化方法验证
                if verifyBySimpleDecryption(data: fileData, password: password) {
                    cryptoLogger.info("🔐 [密码验证] 简化验证通过")
                    return .success(true)
                }
                return .success(false)
            }
            
            cryptoLogger.debug("🔐 [密码验证] 找到 EncryptedPackage 标记")
            
            // 在 EncryptedPackage 之前查找 EncryptionInfo
            let searchStart = max(0, encryptedPackageStart.lowerBound - 8192)
            let searchRange = searchStart..<encryptedPackageStart.lowerBound
            let searchData = fileData.subdata(in: searchRange)
            
            cryptoLogger.debug("🔐 [密码验证] 在偏移 \(searchStart) 到 \(encryptedPackageStart.lowerBound) 范围内搜索 EncryptionInfo")
            
            // 尝试查找 EncryptionInfo 流
            let encryptionInfoData = findEncryptionInfo(in: fileData, before: encryptedPackageStart.lowerBound)
            
            if let encInfo = encryptionInfoData {
                cryptoLogger.debug("🔐 [密码验证] 找到 EncryptionInfo，长度: \(encInfo.count) 字节")
                
                // 尝试 Agile Encryption
                if let result = verifyAgileEncryption(encryptionInfo: encInfo, password: password) {
                    return result
                }
            }
            
            // 尝试简化验证
            cryptoLogger.debug("🔐 [密码验证] 尝试简化验证方法")
            if verifyBySimpleDecryption(data: fileData, password: password) {
                cryptoLogger.info("🔐 [密码验证] 简化验证通过")
                return .success(true)
            }
            
            cryptoLogger.debug("🔐 [密码验证] 所有验证方法均失败")
            return .success(false)
            
        } catch {
            cryptoLogger.error("❌ [密码验证] 文件读取失败: \(error)")
            return .failure(.internalError(error.localizedDescription))
        }
    }
    
    private func findEncryptionInfo(in data: Data, before endOffset: Int) -> Data? {
        // Office 加密文件的 EncryptionInfo 通常在 EncryptedPackage 之前的 4KB 范围内
        // 它可能是：
        // 1. 一个独立的流
        // 2. 嵌入在文件的其他位置
        
        // 首先尝试查找 "EncryptionInfo" 字符串
        let searchRange = max(0, endOffset - 8192)..<endOffset
        let searchData = data.subdata(in: searchRange)
        
        // 查找所有可能的 EncryptionInfo 位置
        var results: [Data] = []
        
        // 尝试作为 XML 解析
        if let xmlString = String(data: searchData, encoding: .utf8) {
            if xmlString.contains("<encryption") || xmlString.contains("keyData") || xmlString.contains("encryptedKey") {
                cryptoLogger.debug("🔐 [密码验证] 找到加密 XML")
                return searchData
            }
        }
        
        // 尝试查找二进制格式的 EncryptionInfo
        // 格式: versionMajor(2) + versionMinor(2) + flags(4) + encryptionInfoSize(4) + ...
        for offset in stride(from: searchData.count - 100, through: 0, by: -1) {
            if offset + 8 <= searchData.count {
                let versionMajor = UInt16(searchData[offset]) | (UInt16(searchData[offset + 1]) << 8)
                let versionMinor = UInt16(searchData[offset + 2]) | (UInt16(searchData[offset + 3]) << 8)
                
                // Agile Encryption 版本通常是 4.4
                if versionMajor == 4 && versionMinor == 4 {
                    cryptoLogger.debug("🔐 [密码验证] 在偏移 \(offset) 找到 Agile Encryption 标记")
                    let infoStart = searchRange.lowerBound + offset
                    return data.subdata(in: infoStart..<endOffset)
                }
                
                // Standard Encryption 版本可能是 2.2, 3.2, 4.2
                if (versionMajor >= 2 && versionMajor <= 4) && versionMinor == 2 {
                    cryptoLogger.debug("🔐 [密码验证] 在偏移 \(offset) 找到 Standard Encryption 标记")
                    let infoStart = searchRange.lowerBound + offset
                    return data.subdata(in: infoStart..<endOffset)
                }
            }
        }
        
        return nil
    }
    
    private func verifyAgileEncryption(encryptionInfo: Data, password: String) -> Result<Bool, CryptoError>? {
        cryptoLogger.debug("🔐 [Agile] 开始验证 Agile Encryption")
        
        // 尝试解析为 XML 格式
        if let xmlString = String(data: encryptionInfo, encoding: .utf8) {
            if xmlString.contains("<encryption") || xmlString.contains("keyData") {
                cryptoLogger.debug("🔐 [Agile] 识别为 XML 格式")
                return verifyAgileXML(xmlString: xmlString, password: password)
            }
        }
        
        // 尝试解析为二进制格式
        return verifyAgileBinary(encryptionInfo: encryptionInfo, password: password)
    }
    
    private func verifyAgileXML(xmlString: String, password: String) -> Result<Bool, CryptoError>? {
        cryptoLogger.debug("🔐 [Agile XML] 开始解析 XML")
        
        // 提取加密参数
        guard let keyDataSalt = extractBase64Value(from: xmlString, tag: "saltValue", parent: "keyData") else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 keyData salt")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 salt，长度: \(keyDataSalt.count)")
        
        guard let passwordSalt = extractBase64Value(from: xmlString, tag: "saltValue", parent: "encryptedKey") else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 password salt")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 password salt，长度: \(passwordSalt.count)")
        
        guard let spinCountStr = extractAttributeValue(from: xmlString, tag: "encryptedKey", attribute: "spinCount"),
              let spinCount = Int(spinCountStr) else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 spinCount，使用默认值 100000")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] spinCount: \(spinCount)")
        
        guard let encryptedKeyValue = extractBase64Value(from: xmlString, tag: "encryptedKeyValue", parent: "encryptedKey") else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 encryptedKeyValue")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 encryptedKeyValue，长度: \(encryptedKeyValue.count)")
        
        guard let encryptedVerifierHashInput = extractBase64Value(from: xmlString, tag: "encryptedVerifierHashInput", parent: "encryptedKey") else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 encryptedVerifierHashInput")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 encryptedVerifierHashInput，长度: \(encryptedVerifierHashInput.count)")
        
        guard let encryptedVerifierHashValue = extractBase64Value(from: xmlString, tag: "encryptedVerifierHashValue", parent: "encryptedKey") else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 encryptedVerifierHashValue")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 encryptedVerifierHashValue，长度: \(encryptedVerifierHashValue.count)")
        
        // 获取哈希算法
        let hashAlgorithm = extractAttributeValue(from: xmlString, tag: "encryptedKey", attribute: "hashAlgorithm") ?? "SHA512"
        cryptoLogger.debug("🔐 [Agile XML] hashAlgorithm: \(hashAlgorithm)")
        
        // 验证密码
        let result = verifyPassword(
            password: password,
            salt: passwordSalt,
            spinCount: spinCount,
            hashAlgorithm: hashAlgorithm,
            encryptedKeyValue: encryptedKeyValue,
            encryptedVerifierHashInput: encryptedVerifierHashInput,
            encryptedVerifierHashValue: encryptedVerifierHashValue
        )
        
        return result ? .success(true) : .success(false)
    }
    
    private func verifyAgileBinary(encryptionInfo: Data, password: String) -> Result<Bool, CryptoError>? {
        guard encryptionInfo.count >= 8 else {
            return nil
        }
        
        cryptoLogger.debug("🔐 [Agile Binary] 开始解析二进制格式")
        
        // 读取版本信息
        let versionMajor = UInt16(encryptionInfo[0]) | (UInt16(encryptionInfo[1]) << 8)
        let versionMinor = UInt16(encryptionInfo[2]) | (UInt16(encryptionInfo[3]) << 8)
        
        cryptoLogger.debug("🔐 [Agile Binary] 版本: \(versionMajor).\(versionMinor)")
        
        // Agile Encryption (4.4) 从偏移 8 开始是 XML
        if versionMajor == 4 && versionMinor == 4 {
            let xmlData = encryptionInfo.subdata(in: 8..<encryptionInfo.count)
            if let xmlString = String(data: xmlData, encoding: .utf8) {
                return verifyAgileXML(xmlString: xmlString, password: password)
            }
        }
        
        return nil
    }
    
    private func extractBase64Value(from xml: String, tag: String, parent: String) -> Data? {
        // 查找父标签
        let parentPattern = "<\(parent)[^>]*>"
        guard let parentRange = xml.range(of: parentPattern, options: .regularExpression) else {
            return nil
        }
        
        // 在父标签内容中查找目标标签
        let parentContent = String(xml[parentRange.upperBound...])
        
        // 查找 saltValue 或 encryptedKeyValue 等标签
        let tagPattern = "<\(tag)>([^<]+)</\(tag)>"
        guard let match = parentContent.range(of: tagPattern, options: .regularExpression) else {
            return nil
        }
        
        let matchString = String(parentContent[match])
        // 提取 base64 值
        let valuePattern = ">([^<]+)<"
        guard let valueMatch = matchString.range(of: valuePattern, options: .regularExpression) else {
            return nil
        }
        
        let base64String = String(matchString[valueMatch]).dropFirst().dropLast()
        return Data(base64Encoded: String(base64String))
    }
    
    private func extractAttributeValue(from xml: String, tag: String, attribute: String) -> String? {
        let tagPattern = "<\(tag)[^>]+>"
        guard let tagRange = xml.range(of: tagPattern, options: .regularExpression) else {
            return nil
        }
        
        let tagString = String(xml[tagRange])
        let attrPattern = "\(attribute)=\"([^\"]+)\""
        
        guard let match = tagString.range(of: attrPattern, options: .regularExpression) else {
            return nil
        }
        
        let matchString = String(tagString[match])
        let valuePattern = "\"[^\"]+\""
        guard let valueMatch = matchString.range(of: valuePattern, options: .regularExpression) else {
            return nil
        }
        
        return String(matchString[valueMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    
    private func verifyPassword(password: String,
                                salt: Data,
                                spinCount: Int,
                                hashAlgorithm: String,
                                encryptedKeyValue: Data,
                                encryptedVerifierHashInput: Data,
                                encryptedVerifierHashValue: Data) -> Bool {
        
        cryptoLogger.debug("🔐 [密码验证] 开始 PBKDF2 密钥派生")
        cryptoLogger.debug("🔐 [密码验证] 密码长度: \(password.count)")
        cryptoLogger.debug("🔐 [密码验证] Salt 长度: \(salt.count)")
        cryptoLogger.debug("🔐 [密码验证] SpinCount: \(spinCount)")
        cryptoLogger.debug("🔐 [密码验证] Hash算法: \(hashAlgorithm)")
        
        // Office 使用 UTF-16LE 编码的密码
        let passwordData = password.data(using: .utf16LittleEndian)!
        
        // PBKDF2 派生密钥
        let derivedKey = pbkdf2(
            password: passwordData,
            salt: salt,
            iterations: spinCount,
            keyLength: 64, // 32字节密钥 + 32字节HMAC密钥
            hashAlgorithm: hashAlgorithm
        )
        
        cryptoLogger.debug("🔐 [密码验证] 派生密钥长度: \(derivedKey.count)")
        
        guard derivedKey.count >= 64 else {
            cryptoLogger.error("❌ [密码验证] 派生密钥长度不足")
            return false
        }
        
        let encryptionKey = derivedKey.prefix(32)
        let hmacKey = derivedKey.suffix(32)
        
        cryptoLogger.debug("🔐 [密码验证] 加密密钥长度: \(encryptionKey.count)")
        cryptoLogger.debug("🔐 [密码验证] HMAC密钥长度: \(hmacKey)")
        
        // 使用 AES-256-CBC 解密 encryptedVerifierHashInput
        let decryptedHashInput = aesDecrypt(
            data: encryptedVerifierHashInput,
            key: encryptionKey,
            iv: Data(repeating: 0, count: 16)
        )
        
        cryptoLogger.debug("🔐 [密码验证] 解密后的 HashInput 长度: \(decryptedHashInput?.count ?? 0)")
        
        guard let hashInput = decryptedHashInput, hashInput.count >= 16 else {
            cryptoLogger.error("❌ [密码验证] 解密 HashInput 失败")
            return false
        }
        
        // 计算解密数据的 Hash
        let verifierHash = hashData(
            data: hashInput,
            algorithm: hashAlgorithm
        )
        
        cryptoLogger.debug("🔐 [密码验证] 计算的 VerifierHash 长度: \(verifierHash.count)")
        
        // 使用 HMAC 计算
        let calculatedHmac = hmac(
            data: hashInput,
            key: hmacKey,
            algorithm: hashAlgorithm
        )
        
        cryptoLogger.debug("🔐 [密码验证] 计算的 HMAC 长度: \(calculatedHmac.count)")
        
        // 比较前 20 字节（SHA-1 的长度）
        let hashLength = min(verifierHash.count, encryptedVerifierHashValue.count)
        
        let encryptedVerifierHashPrefix = encryptedVerifierHashValue.prefix(hashLength)
        let calculatedHashPrefix = calculatedHmac.prefix(hashLength)
        
        let isValid = encryptedVerifierHashPrefix.elementsEqual(calculatedHashPrefix)
        
        cryptoLogger.debug("🔐 [密码验证] 验证结果: \(isValid)")
        
        return isValid
    }
    
    private func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int, hashAlgorithm: String) -> Data {
        var result = [UInt8](repeating: 0, count: keyLength)
        
        let prfAlgorithm: CCPseudoRandomAlgorithm
        if hashAlgorithm.lowercased().contains("sha256") {
            prfAlgorithm = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        } else if hashAlgorithm.lowercased().contains("sha1") {
            prfAlgorithm = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        } else {
            prfAlgorithm = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        }
        
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress,
                    password.count,
                    saltBytes.baseAddress,
                    salt.count,
                    prfAlgorithm,
                    UInt32(iterations),
                    &result,
                    keyLength
                )
            }
        }
        
        if status != kCCSuccess {
            cryptoLogger.error("❌ [密码验证] PBKDF2 失败，状态码: \(status)")
            return Data()
        }
        
        return Data(result)
    }
    
    private func deriveKeyForStandardEncryption(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        guard let passwordData = password.data(using: .utf16LittleEndian) else {
            return Data()
        }
        
        var ctx = CC_SHA1_CTX()
        CC_SHA1_Init(&ctx)
        _ = salt.withUnsafeBytes { CC_SHA1_Update(&ctx, $0.baseAddress, CC_LONG(salt.count)) }
        _ = passwordData.withUnsafeBytes { CC_SHA1_Update(&ctx, $0.baseAddress, CC_LONG(passwordData.count)) }
        var currentHash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&currentHash, &ctx)
        
        for i in 0..<iterations {
            CC_SHA1_Init(&ctx)
            CC_SHA1_Update(&ctx, &currentHash, CC_LONG(currentHash.count))
            var iterBytes = UInt32(i).littleEndian
            CC_SHA1_Update(&ctx, &iterBytes, 4)
            CC_SHA1_Final(&currentHash, &ctx)
        }
        
        CC_SHA1_Init(&ctx)
        CC_SHA1_Update(&ctx, &currentHash, CC_LONG(currentHash.count))
        var blockZero = UInt32(0).littleEndian
        CC_SHA1_Update(&ctx, &blockZero, 4)
        var finalHash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&finalHash, &ctx)
        
        return Data(finalHash[0..<keyLength])
    }
    
    private func aesDecrypt(data: Data, key: Data.SubSequence, iv: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0
        
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress,
                        data.count,
                        &decryptedBytes,
                        bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }
        
        if status != kCCSuccess {
            cryptoLogger.error("❌ [密码验证] AES 解密失败，状态码: \(status)")
            return nil
        }
        
        return Data(decryptedBytes.prefix(numBytesDecrypted))
    }
    
    private func aesECBDecrypt(data: Data, key: Data.SubSequence) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0
        
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    dataBytes.baseAddress,
                    data.count,
                    &decryptedBytes,
                    bufferSize,
                    &numBytesDecrypted
                )
            }
        }
        
        if status != kCCSuccess {
            cryptoLogger.error("❌ [密码验证] AES-ECB 解密失败，状态码: \(status)")
            return nil
        }
        
        return Data(decryptedBytes.prefix(numBytesDecrypted))
    }
    
    private func hashData(data: Data, algorithm: String) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        
        if algorithm.lowercased().contains("sha512") {
            data.withUnsafeBytes { bytes in
                CC_SHA512(bytes.baseAddress, CC_LONG(data.count), &hash)
            }
        } else if algorithm.lowercased().contains("sha256") {
            var sha256Hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &sha256Hash)
            }
            return Data(sha256Hash)
        } else {
            var sha1Hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes { bytes in
                CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &sha1Hash)
            }
            return Data(sha1Hash)
        }
        
        return Data(hash)
    }
    
    private func hmac(data: Data, key: Data.SubSequence, algorithm: String) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        
        let hmacAlgorithm: CCHmacAlgorithm
        if algorithm.lowercased().contains("sha256") {
            hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
        } else if algorithm.lowercased().contains("sha1") {
            hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA1)
        } else {
            hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA512)
        }
        
        key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(
                    hmacAlgorithm,
                    keyBytes.baseAddress,
                    key.count,
                    dataBytes.baseAddress,
                    data.count,
                    &hmac
                )
            }
        }
        
        return Data(hmac)
    }
    
    private func analyzeFileStructure(data: Data) {
        cryptoLogger.info("🔍 [文件分析] 开始分析文件结构")
        
        // 打印文件头 32 字节
        let headerLength = min(32, data.count)
        let header = data.prefix(headerLength)
        let hexString = header.map { String(format: "%02X ", $0) }.joined()
        cryptoLogger.info("🔍 [文件分析] 文件头 32 字节: \(hexString)")
        
        // 检查各种魔数
        let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])
        
        if data.starts(with: Data(ole2Magic)) {
            cryptoLogger.info("🔍 [文件分析] 识别为 OLE2 复合文档")
        } else if data.starts(with: zipMagic) {
            cryptoLogger.info("🔍 [文件分析] 识别为 ZIP 文件（可能是未加密的 OOXML）")
        } else {
            cryptoLogger.info("🔍 [文件分析] 文件魔数未知")
        }
        
        // 搜索 EncryptionInfo
        if let encInfoRange = data.range(of: "EncryptionInfo".data(using: .utf8)!) {
            cryptoLogger.info("🔍 [文件分析] 找到 EncryptionInfo，偏移: \(encInfoRange.lowerBound)")
        } else {
            cryptoLogger.info("🔍 [文件分析] 未找到 EncryptionInfo")
        }
        
        // 搜索 EncryptedPackage
        if let encPackageRange = data.range(of: "EncryptedPackage".data(using: .utf8)!) {
            cryptoLogger.info("🔍 [文件分析] 找到 EncryptedPackage，偏移: \(encPackageRange.lowerBound)")
        } else {
            cryptoLogger.info("🔍 [文件分析] 未找到 EncryptedPackage")
        }
        
        // 搜索 keyData
        if let keyDataRange = data.range(of: "<keyData".data(using: .utf8)!) {
            cryptoLogger.info("🔍 [文件分析] 找到 <keyData，偏移: \(keyDataRange.lowerBound)")
        } else {
            cryptoLogger.info("🔍 [文件分析] 未找到 <keyData")
        }
        
        // 搜索 encryptedKey
        if let encryptedKeyRange = data.range(of: "<encryptedKey".data(using: .utf8)!) {
            cryptoLogger.info("🔍 [文件分析] 找到 <encryptedKey，偏移: \(encryptedKeyRange.lowerBound)")
        } else {
            cryptoLogger.info("🔍 [文件分析] 未找到 <encryptedKey")
        }
    }
    
    private func isOLE2Format(data: Data) -> Bool {
        let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        return data.starts(with: Data(ole2Magic))
    }
    
    private func verifyOLE2Password(data: Data, password: String) -> Result<Bool, CryptoError> {
        cryptoLogger.info("🔐 [OLE2] 开始验证 OLE2 格式密码")
        
        // 使用轻量级 OLE2 解析器读取 EncryptionInfo 流
        if let ole2Parser = OLE2Parser(data: data) {
            cryptoLogger.info("🔐 [OLE2] OLE2 解析器初始化成功")
            
            // 打印所有流名称以便调试
            ole2Parser.listAllStreams()
            
            // 尝试读取 EncryptionInfo 流
            if let encryptionInfo = ole2Parser.readStream(name: "EncryptionInfo") {
                cryptoLogger.info("🔐 [OLE2] 找到 EncryptionInfo 流，长度: \(encryptionInfo.count)")
                cryptoLogger.debug("🔐 [OLE2] EncryptionInfo 前 32 字节: \(encryptionInfo.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " "))")
                
                // 尝试解析
                if let result = verifyEncryptionInfo(encryptionInfo, password: password) {
                    return result
                }
            } else {
                cryptoLogger.warning("🔐 [OLE2] 未找到 EncryptionInfo 流")
            }
            
            // 尝试读取 EncryptedPackage 流
            if let encryptedPackage = ole2Parser.readStream(name: "EncryptedPackage") {
                cryptoLogger.info("🔐 [OLE2] 找到 EncryptedPackage 流，长度: \(encryptedPackage.count)")
            }
        } else {
            cryptoLogger.warning("🔐 [OLE2] OLE2 解析器初始化失败")
        }
        
        // 尝试直接搜索加密信息
        let result = verifyStandardEncryption(data: data, password: password)
        
        if result {
            return .success(true)
        }
        
        // 尝试 Agile Encryption（也可能封装在 OLE2 中）
        if let encInfoRange = data.range(of: "EncryptionInfo".data(using: .utf8)!) {
            let searchStart = max(0, encInfoRange.lowerBound - 100)
            let encInfoData = data.subdata(in: searchStart..<min(data.count, encInfoRange.upperBound + 4096))
            
            if let agileResult = verifyAgileEncryption(encryptionInfo: encInfoData, password: password) {
                return agileResult
            }
        }
        
        // 尝试用密码解密文件头验证
        if verifyOLE2ByDecryptingHeader(data: data, password: password) {
            cryptoLogger.info("🔐 [OLE2] 通过解密文件头验证成功")
            return .success(true)
        }
        
        cryptoLogger.debug("🔐 [OLE2] 所有 OLE2 验证方法均失败")
        return .success(false)
    }
    
    private func verifyEncryptionInfo(_ encryptionInfo: Data, password: String) -> Result<Bool, CryptoError>? {
        cryptoLogger.info("🔐 [EncryptionInfo] 开始解析，长度: \(encryptionInfo.count)")
        
        // 打印完整的 EncryptionInfo 数据用于调试
        let fullHexString = encryptionInfo.map { String(format: "%02X ", $0) }.joined()
        cryptoLogger.info("🔐 [EncryptionInfo] 完整 \(encryptionInfo.count) 字节: \(fullHexString)")
        
        guard encryptionInfo.count >= 8 else {
            return nil
        }
        
        // 尝试不同的格式
        // 1. 标准二进制格式：version(2) + flags(2) + ...
        // 2. Agile 格式：version(4) + xml...
        
        // 检查是否为 XML 格式
        if let xmlString = String(data: encryptionInfo, encoding: .utf8) {
            if xmlString.contains("<?xml") || xmlString.contains("<encryption") {
                cryptoLogger.info("🔐 [EncryptionInfo] 识别为 XML 格式")
                return verifyAgileXML(xmlString: xmlString, password: password)
            }
        }
        
        // 尝试标准格式
        // Office 2007+ 的 EncryptionInfo 格式：
        // - versionMajor (2 bytes, little-endian)
        // - versionMinor (2 bytes, little-endian)
        // - flags (4 bytes, little-endian) - 标准加密为 0，Agile 为 0x40
        // - 后续数据取决于版本
        
        let versionMajor = UInt16(encryptionInfo[0]) | (UInt16(encryptionInfo[1]) << 8)
        let versionMinor = UInt16(encryptionInfo[2]) | (UInt16(encryptionInfo[3]) << 8)
        let flags = UInt32(encryptionInfo[4]) | (UInt32(encryptionInfo[5]) << 8) | (UInt32(encryptionInfo[6]) << 16) | (UInt32(encryptionInfo[7]) << 24)
        
        cryptoLogger.info("🔐 [EncryptionInfo] 版本: \(versionMajor).\(versionMinor), Flags: \(String(format: "%08X", flags))")
        
        // Agile Encryption: version 4.4
        if versionMajor == 4 && versionMinor == 4 {
            cryptoLogger.info("🔐 [EncryptionInfo] 识别为 Agile Encryption")
            let xmlData = encryptionInfo.subdata(in: 8..<encryptionInfo.count)
            if let xmlString = String(data: xmlData, encoding: .utf8) {
                cryptoLogger.debug("🔐 [EncryptionInfo] XML 长度: \(xmlString.count)")
                return verifyAgileXML(xmlString: xmlString, password: password)
            }
        }
        
        // Standard Encryption: version 2.2, 3.2, 4.2
        if (versionMajor >= 2 && versionMajor <= 4) && versionMinor == 2 {
            cryptoLogger.info("🔐 [EncryptionInfo] 识别为 Standard Encryption")
            return verifyStandardBinaryEncryption(encryptionInfo: encryptionInfo, password: password)
        }
        
        // WPS 可能使用自定义格式
        // 尝试查找 XML 片段
        let xmlSearchRange = 8..<min(encryptionInfo.count, 4096)
        let xmlSearchData = encryptionInfo.subdata(in: xmlSearchRange)
        if let xmlString = String(data: xmlSearchData, encoding: .utf8) {
            if xmlString.contains("<") && xmlString.contains(">") {
                cryptoLogger.info("🔐 [EncryptionInfo] 在数据中发现 XML 片段，尝试解析")
                return verifyAgileXML(xmlString: xmlString, password: password)
            }
        }
        
        cryptoLogger.warning("🔐 [EncryptionInfo] 无法识别的格式")
        return nil
    }
    
    private func verifyStandardBinaryEncryption(encryptionInfo: Data, password: String) -> Result<Bool, CryptoError>? {
        cryptoLogger.info("🔐 [标准二进制] 开始解析，总长度: \(encryptionInfo.count)")
        
        guard encryptionInfo.count >= 44 else {
            cryptoLogger.warning("🔐 [标准二进制] 数据长度不足")
            return nil
        }
        
        let headerSize = UInt32(encryptionInfo[8]) | (UInt32(encryptionInfo[9]) << 8) | (UInt32(encryptionInfo[10]) << 16) | (UInt32(encryptionInfo[11]) << 24)
        
        let hFlags = UInt32(encryptionInfo[12]) | (UInt32(encryptionInfo[13]) << 8) | (UInt32(encryptionInfo[14]) << 16) | (UInt32(encryptionInfo[15]) << 24)
        let sizeExtra = UInt32(encryptionInfo[16]) | (UInt32(encryptionInfo[17]) << 8) | (UInt32(encryptionInfo[18]) << 16) | (UInt32(encryptionInfo[19]) << 24)
        let algId = UInt32(encryptionInfo[20]) | (UInt32(encryptionInfo[21]) << 8) | (UInt32(encryptionInfo[22]) << 16) | (UInt32(encryptionInfo[23]) << 24)
        let algIdHash = UInt32(encryptionInfo[24]) | (UInt32(encryptionInfo[25]) << 8) | (UInt32(encryptionInfo[26]) << 16) | (UInt32(encryptionInfo[27]) << 24)
        let keySize = UInt32(encryptionInfo[28]) | (UInt32(encryptionInfo[29]) << 8) | (UInt32(encryptionInfo[30]) << 16) | (UInt32(encryptionInfo[31]) << 24)
        let providerType = UInt32(encryptionInfo[32]) | (UInt32(encryptionInfo[33]) << 8) | (UInt32(encryptionInfo[34]) << 16) | (UInt32(encryptionInfo[35]) << 24)
        
        cryptoLogger.info("🔐 [标准二进制] headerSize: \(String(format: "%08X", headerSize)), hFlags: \(String(format: "%08X", hFlags))")
        cryptoLogger.info("🔐 [标准二进制] algId: \(String(format: "%08X", algId)), algIdHash: \(String(format: "%08X", algIdHash))")
        cryptoLogger.info("🔐 [标准二进制] keySize: \(keySize), providerType: \(String(format: "%08X", providerType))")
        
        let realKeySizeInBytes = (keySize == 0) ? 16 : Int(keySize / 8)
        cryptoLogger.info("🔐 [标准二进制] 实际密钥长度: \(realKeySizeInBytes) 字节")
        
        let verifierStart = 12 + Int(headerSize)
        
        guard encryptionInfo.count >= verifierStart + 4 else {
            cryptoLogger.warning("🔐 [标准二进制] 结构异常，缺少 Verifier 结构")
            return nil
        }
        
        let saltSize = UInt32(encryptionInfo[verifierStart]) | (UInt32(encryptionInfo[verifierStart + 1]) << 8) | (UInt32(encryptionInfo[verifierStart + 2]) << 16) | (UInt32(encryptionInfo[verifierStart + 3]) << 24)
        
        let saltOffset = verifierStart + 4
        let verifierOffset = saltOffset + Int(saltSize)
        let verifierHashSizeOffset = verifierOffset + 16
        
        guard encryptionInfo.count >= verifierHashSizeOffset + 4 else {
            cryptoLogger.warning("🔐 [标准二进制] 结构异常，无法读取 VerifierHash")
            return nil
        }
        
        let verifierHashSize = UInt32(encryptionInfo[verifierHashSizeOffset]) | (UInt32(encryptionInfo[verifierHashSizeOffset + 1]) << 8) | (UInt32(encryptionInfo[verifierHashSizeOffset + 2]) << 16) | (UInt32(encryptionInfo[verifierHashSizeOffset + 3]) << 24)
        let verifierHashOffset = verifierHashSizeOffset + 4
        
        let actualHashSize = Int(verifierHashSize)
        let encryptedHashSize = (actualHashSize + 15) & ~15
        
        guard encryptionInfo.count >= verifierHashOffset + encryptedHashSize else {
            cryptoLogger.warning("🔐 [标准二进制] 数据截断，无法完整提取密文")
            return nil
        }
        
        let salt = encryptionInfo.subdata(in: saltOffset..<saltOffset + Int(saltSize))
        let encryptedVerifier = encryptionInfo.subdata(in: verifierOffset..<verifierOffset + 16)
        let encryptedVerifierHash = encryptionInfo.subdata(in: verifierHashOffset..<verifierHashOffset + encryptedHashSize)
        
        cryptoLogger.info("🔐 [标准二进制] salt 长度: \(salt.count), verifier 长度: \(encryptedVerifier.count), hash 长度: \(encryptedVerifierHash.count)")
        
        let saltHex = salt.map { String(format: "%02X", $0) }.joined()
        let verifierHex = encryptedVerifier.map { String(format: "%02X", $0) }.joined()
        let hashHex = encryptedVerifierHash.map { String(format: "%02X", $0) }.joined()
        cryptoLogger.info("🔐 [标准二进制] salt: \(saltHex)")
        cryptoLogger.info("🔐 [标准二进制] encryptedVerifier: \(verifierHex)")
        cryptoLogger.info("🔐 [标准二进制] encryptedVerifierHash: \(hashHex)")
        
        let success = verifyStandardPassword(
            salt: salt,
            encryptedVerifier: encryptedVerifier,
            encryptedVerifierHash: encryptedVerifierHash,
            keySizeInBytes: realKeySizeInBytes,
            password: password
        )
        
        return .success(success)
    }
    
    private func verifyStandardPassword(salt: Data, encryptedVerifier: Data, encryptedVerifierHash: Data, keySizeInBytes: Int, password: String) -> Bool {
        guard let passwordData = password.data(using: .utf16LittleEndian) else {
            cryptoLogger.error("🔐 [标准二进制] 密码编码失败")
            return false
        }
        
        var ctx = CC_SHA1_CTX()
        var hashBuffer = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        
        CC_SHA1_Init(&ctx)
        salt.withUnsafeBytes { CC_SHA1_Update(&ctx, $0.baseAddress, CC_LONG($0.count)) }
        passwordData.withUnsafeBytes { CC_SHA1_Update(&ctx, $0.baseAddress, CC_LONG($0.count)) }
        CC_SHA1_Final(&hashBuffer, &ctx)
        
        var currentHashData = Data(hashBuffer)
        
        for i in 0..<50000 {
            CC_SHA1_Init(&ctx)
            
            var iterBytes = UInt32(i).littleEndian
            withUnsafeBytes(of: iterBytes) { bytes in
                CC_SHA1_Update(&ctx, bytes.baseAddress, 4)
            }
            
            currentHashData.withUnsafeBytes { bytes in
                CC_SHA1_Update(&ctx, bytes.baseAddress, CC_LONG(bytes.count))
            }
            
            CC_SHA1_Final(&hashBuffer, &ctx)
            currentHashData = Data(hashBuffer)
        }
        
        CC_SHA1_Init(&ctx)
        currentHashData.withUnsafeBytes { bytes in
            CC_SHA1_Update(&ctx, bytes.baseAddress, CC_LONG(bytes.count))
        }
        var blockZero = UInt32(0).littleEndian
        withUnsafeBytes(of: blockZero) { bytes in
            CC_SHA1_Update(&ctx, bytes.baseAddress, 4)
        }
        CC_SHA1_Final(&hashBuffer, &ctx)
        
        let finalHashData = Data(hashBuffer)
        
        let x1 = fillAndXor(hash: finalHashData, fillByte: 0x36)
        let x2 = fillAndXor(hash: finalHashData, fillByte: 0x5c)
        
        let x3 = x1 + x2
        let aesKey = x3.prefix(keySizeInBytes)
        
        let keyHex = aesKey.map { String(format: "%02X", $0) }.joined()
        cryptoLogger.info("🔐 [标准二进制] 最终派生密钥: \(keyHex)")
        
        guard let decryptedVerifier = aes128EcbDecrypt(data: encryptedVerifier, key: aesKey),
              let decryptedVerifierHash = aes128EcbDecrypt(data: encryptedVerifierHash, key: aesKey) else {
            cryptoLogger.error("🔐 [标准二进制] AES 解密操作执行失败")
            return false
        }
        
        let decryptedVerifierHex = decryptedVerifier.map { String(format: "%02X", $0) }.joined()
        let decryptedHashHex = decryptedVerifierHash.map { String(format: "%02X", $0) }.joined()
        cryptoLogger.info("🔐 [标准二进制] 解密后 verifier: \(decryptedVerifierHex)")
        cryptoLogger.info("🔐 [标准二进制] 解密后 verifierHash: \(decryptedHashHex)")
        
        CC_SHA1_Init(&ctx)
        decryptedVerifier.withUnsafeBytes { CC_SHA1_Update(&ctx, $0.baseAddress, CC_LONG($0.count)) }
        CC_SHA1_Final(&hashBuffer, &ctx)
        
        let computedHashData = Data(hashBuffer)
        
        let computedHex = computedHashData.map { String(format: "%02X", $0) }.joined()
        let expectedHex = decryptedVerifierHash.prefix(20).map { String(format: "%02X", $0) }.joined()
        cryptoLogger.info("🔐 [标准二进制] 计算出的 VerifierHash: \(computedHex)")
        cryptoLogger.info("🔐 [标准二进制] 解密出的 VerifierHash: \(expectedHex)")
        
        let isValid = computedHashData == decryptedVerifierHash.prefix(20)
        cryptoLogger.info("🔐 [标准二进制] 最终校验结果: \(isValid)")
        
        return isValid
    }
    
    private func fillAndXor(hash: Data, fillByte: UInt8) -> Data {
        var buff = [UInt8](repeating: fillByte, count: 64)
        
        for i in 0..<hash.count {
            buff[i] ^= hash[i]
        }
        
        var ctx = CC_SHA1_CTX()
        CC_SHA1_Init(&ctx)
        CC_SHA1_Update(&ctx, buff, CC_LONG(buff.count))
        
        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1_Final(&result, &ctx)
        
        return Data(result)
    }
    
    private func aes128EcbDecrypt(data: Data, key: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0
        
        let cryptStatus = buffer.withUnsafeMutableBytes { cryptBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count,
                            nil,
                            dataBytes.baseAddress, data.count,
                            cryptBytes.baseAddress, bufferSize,
                            &numBytesDecrypted)
                }
            }
        }
        
        if cryptStatus == kCCSuccess {
            return buffer.prefix(numBytesDecrypted)
        }
        cryptoLogger.error("🔐 [标准二进制] AES-ECB 解密失败，状态码: \(cryptStatus)")
        return nil
    }
    
    private func verifyStandardEncryption(data: Data, password: String) -> Bool {
        cryptoLogger.info("🔐 [标准加密] 尝试标准加密验证")
        
        // 搜索 EncryptionInfo 结构
        // 格式：version(4) + flags(4) + size(4) + ...
        
        for offset in stride(from: 0, to: min(data.count - 12, 500), by: 1) {
            if data.count < offset + 12 {
                break
            }
            
            let versionMajor = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let versionMinor = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
            let flags = UInt32(data[offset + 4]) | (UInt32(data[offset + 5]) << 8) | (UInt32(data[offset + 6]) << 16) | (UInt32(data[offset + 7]) << 24)
            let infoSize = UInt32(data[offset + 8]) | (UInt32(data[offset + 9]) << 8) | (UInt32(data[offset + 10]) << 16) | (UInt32(data[offset + 11]) << 24)
            
            // 标准加密版本通常是 2.2, 3.2, 4.2
            // Agile 加密版本是 4.4
            if (versionMajor >= 2 && versionMajor <= 4) && (versionMinor == 2 || versionMinor == 4) {
                cryptoLogger.debug("🔐 [标准加密] 在偏移 \(offset) 找到加密信息，版本: \(versionMajor).\(versionMinor)")
                
                // 尝试解析
                let infoStart = offset + 12
                if infoStart + Int(infoSize) <= data.count {
                    let infoData = data.subdata(in: infoStart..<infoStart + Int(infoSize))
                    
                    if versionMajor == 4 && versionMinor == 4 {
                        // Agile Encryption - XML 格式
                        if let xmlString = String(data: infoData, encoding: .utf8) {
                            if let result = verifyAgileXML(xmlString: xmlString, password: password) {
                                return result == .success(true)
                            }
                        }
                    } else {
                        // Standard Encryption - 二进制格式
                        if verifyStandardBinary(data: infoData, password: password) {
                            return true
                        }
                    }
                }
            }
        }
        
        return false
    }
    
    private func verifyStandardBinary(data: Data, password: String) -> Bool {
        cryptoLogger.info("🔐 [标准加密] 尝试二进制格式验证")
        
        // 标准加密格式解析（参考 Apache POI）
        // EncryptionHeader:
        // - algId (4 bytes)
        // - algIdHash (4 bytes)
        // - keySize (4 bytes)
        // - providerType (4 bytes)
        // - reserved1 (4 bytes)
        // - reserved2 (4 bytes)
        // - keyData (variable)
        
        // EncryptionVerifier:
        // - saltSize (4 bytes)
        // - salt (variable)
        // - encryptedVerifierHashInput (16 bytes)
        // - encryptedVerifierHashValue (16 bytes)
        
        guard data.count >= 24 else {
            return false
        }
        
        let algId = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        let algIdHash = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        let keySize = UInt32(data[8]) | (UInt32(data[9]) << 8) | (UInt32(data[10]) << 16) | (UInt32(data[11]) << 24)
        
        cryptoLogger.debug("🔐 [标准加密] algId: \(String(format: "%08X", algId))")
        cryptoLogger.debug("🔐 [标准加密] algIdHash: \(String(format: "%08X", algIdHash))")
        cryptoLogger.debug("🔐 [标准加密] keySize: \(keySize)")
        
        // 解析 EncryptionVerifier
        var offset = 24
        
        if offset + 4 > data.count {
            return false
        }
        let saltSize = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        offset += 4
        
        if offset + Int(saltSize) > data.count {
            return false
        }
        let salt = data.subdata(in: offset..<offset + Int(saltSize))
        offset += Int(saltSize)
        
        if offset + 16 + 16 > data.count {
            return false
        }
        let encryptedVerifierHashInput = data.subdata(in: offset..<offset + 16)
        offset += 16
        let encryptedVerifierHashValue = data.subdata(in: offset..<offset + 16)
        
        cryptoLogger.debug("🔐 [标准加密] salt 长度: \(salt.count)")
        cryptoLogger.debug("🔐 [标准加密] encryptedVerifierHashInput 长度: \(encryptedVerifierHashInput.count)")
        cryptoLogger.debug("🔐 [标准加密] encryptedVerifierHashValue 长度: \(encryptedVerifierHashValue.count)")
        
        // 派生密钥
        let passwordData = password.data(using: .utf16LittleEndian)!
        let derivedKey = pbkdf2(
            password: passwordData,
            salt: salt,
            iterations: 50000, // Office 标准加密默认迭代次数
            keyLength: Int(keySize / 8),
            hashAlgorithm: "SHA1"
        )
        
        cryptoLogger.debug("🔐 [标准加密] 派生密钥长度: \(derivedKey.count)")
        
        if derivedKey.count == 0 {
            return false
        }
        
        // 解密 verifierHashInput
        let decryptedHashInput = aesDecrypt(
            data: encryptedVerifierHashInput,
            key: derivedKey.prefix(min(derivedKey.count, 32)),
            iv: Data(repeating: 0, count: 16)
        )
        
        cryptoLogger.debug("🔐 [标准加密] 解密后的 HashInput 长度: \(decryptedHashInput?.count ?? 0)")
        
        guard let hashInput = decryptedHashInput, hashInput.count >= 16 else {
            return false
        }
        
        // 计算 Hash
        let verifierHash = hashInput.sha1()
        
        // 解密 encryptedVerifierHashValue
        let decryptedVerifierHashValue = aesDecrypt(
            data: encryptedVerifierHashValue,
            key: derivedKey.prefix(min(derivedKey.count, 32)),
            iv: Data(repeating: 0, count: 16)
        )
        
        cryptoLogger.debug("🔐 [标准加密] 解密后的 VerifierHashValue 长度: \(decryptedVerifierHashValue?.count ?? 0)")
        
        guard let expectedHash = decryptedVerifierHashValue else {
            return false
        }
        
        // 比较前 20 字节（SHA-1 长度）
        let isValid = verifierHash.prefix(20).elementsEqual(expectedHash.prefix(20))
        
        cryptoLogger.debug("🔐 [标准加密] 验证结果: \(isValid)")
        
        return isValid
    }
    
    private func verifyOLE2ByDecryptingHeader(data: Data, password: String) -> Bool {
        cryptoLogger.info("🔐 [OLE2] 尝试通过解密文件头验证")
        
        // OLE2 加密文件的前几个扇区通常使用 RC4 或 AES 加密
        // 如果密码正确，可以解密出有效的 OLE2 结构
        
        guard data.count >= 512 else {
            return false
        }
        
        // 尝试 RC4 解密（旧版 Office 使用）
        let rc4Result = tryRC4Decryption(data: data, password: password)
        if rc4Result {
            return true
        }
        
        // 尝试 AES 解密
        let aesResult = tryAESDecryption(data: data, password: password)
        if aesResult {
            return true
        }
        
        return false
    }
    
    private func tryRC4Decryption(data: Data, password: String) -> Bool {
        cryptoLogger.debug("🔐 [RC4] 尝试 RC4 解密")
        
        // RC4 密钥派生（Office 标准加密）
        // 密码 + salt + spinCount -> SHA-1 -> 密钥
        
        // 尝试从文件中提取 salt
        // 在 EncryptionVerifier 中通常有 salt
        
        // 简单尝试：使用密码的 SHA-1 作为 RC4 密钥
        let passwordKey = password.data(using: .utf16LittleEndian)?.sha1() ?? Data()
        
        if passwordKey.count == 0 {
            return false
        }
        
        // RC4 解密前 16 字节
        let decrypted = rc4Decrypt(data: data.prefix(16), key: passwordKey)
        
        let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        
        if decrypted.starts(with: Data(ole2Magic)) {
            cryptoLogger.debug("🔐 [RC4] 解密后匹配 OLE2 魔数")
            return true
        }
        
        return false
    }
    
    private func tryAESDecryption(data: Data, password: String) -> Bool {
        cryptoLogger.debug("🔐 [AES] 尝试 AES 解密")
        
        // 尝试用密码派生密钥并解密
        // Office 使用多种密钥派生方式
        
        // 尝试简单的密钥派生：密码 SHA-1 -> 16/32 字节密钥
        let passwordKey = password.data(using: .utf16LittleEndian)?.sha1() ?? Data()
        
        if passwordKey.count >= 16 {
            let key16 = passwordKey.prefix(16)
            let decrypted16 = aesDecrypt(
                data: data.prefix(min(16, data.count)),
                key: key16,
                iv: Data(repeating: 0, count: 16)
            )
            
            if let decrypted = decrypted16 {
                let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
                if decrypted.starts(with: Data(ole2Magic)) {
                    cryptoLogger.debug("🔐 [AES] 解密后匹配 OLE2 魔数")
                    return true
                }
            }
        }
        
        if passwordKey.count >= 32 {
            let key32 = passwordKey.prefix(32)
            let decrypted32 = aesDecrypt(
                data: data.prefix(min(16, data.count)),
                key: key32,
                iv: Data(repeating: 0, count: 16)
            )
            
            if let decrypted = decrypted32 {
                let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
                if decrypted.starts(with: Data(ole2Magic)) {
                    cryptoLogger.debug("🔐 [AES] 解密后匹配 OLE2 魔数")
                    return true
                }
            }
        }
        
        return false
    }
    
    private func rc4Decrypt(data: Data, key: Data) -> Data {
        guard key.count > 0 else {
            return data
        }
        
        var S = [UInt8](0...255)
        var j: UInt8 = 0
        
        // Key-scheduling algorithm
        for i in 0...255 {
            j = j &+ S[i] &+ key[i % key.count]
            S.swapAt(i, Int(j))
        }
        
        // Pseudo-random generation algorithm
        var i: UInt8 = 0
        j = 0
        var result = Data()
        
        for byte in data {
            i = i &+ 1
            j = j &+ S[Int(i)]
            S.swapAt(Int(i), Int(j))
            let t = S[Int(i)] &+ S[Int(j)]
            result.append(byte ^ S[Int(t)])
        }
        
        return result
    }
    
    private func verifyBySimpleDecryption(data: Data, password: String) -> Bool {
        cryptoLogger.debug("🔐 [简化验证] 开始简化验证")
        
        // Office Agile Encryption 文件的前 16 字节通常是加密的
        // 如果我们能用密码"解密"出 ZIP 魔数 (50 4B 03 04)，说明密码正确
        // 或者能解密出 OLE2 魔数 (D0 CF 11 E0 A1 B1 1A E1)
        
        guard data.count >= 16 else {
            return false
        }
        
        // Office 使用 SHA-1 派生加密密钥
        let passwordKey = password.data(using: .utf8)?.sha1() ?? Data()
        let testKey = Data(passwordKey.prefix(16))
        
        // XOR 解密（简化版，实际 Office 使用 AES）
        let firstBlock = data.prefix(16)
        var decrypted = Data()
        for (i, byte) in firstBlock.enumerated() {
            decrypted.append(byte ^ testKey[i % testKey.count])
        }
        
        // 检查是否解密出有效魔数
        let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])
        let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        
        if decrypted.prefix(4) == zipMagic {
            cryptoLogger.debug("🔐 [简化验证] 解密后匹配 ZIP 魔数")
            return true
        }
        
        if decrypted.starts(with: Data(ole2Magic)) {
            cryptoLogger.debug("🔐 [简化验证] 解密后匹配 OLE2 魔数")
            return true
        }
        
        return false
    }
}

// MARK: - 轻量级 OLE2 复合文档解析器
// 参考 MS-CFB 规范和 Apache POI 的 POIFSFileSystem 实现
class OLE2Parser {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private var difat: [Int]
    private var fat: [Int]
    private let rootEntrySector: Int
    private let miniStreamCutoff: Int
    
    // FAT 特殊值
    private let FREESECT: Int = 0xFFFFFFFF
    private let ENDOFCHAIN: Int = 0xFFFFFFFE
    private let FATSECT: Int = 0xFFFFFFFD
    private let DIFSECT: Int = 0xFFFFFFFC
    
    // 目录项类型
    private enum DirectoryType: UInt8 {
        case unknown = 0
        case storage = 1
        case stream = 2
        case root = 5
    }
    
    private struct DirectoryEntry {
        let name: String
        let type: DirectoryType
        let startSector: Int
        let size: Int
        let childID: Int
        let leftID: Int
        let rightID: Int
    }
    
    init?(data: Data) {
        guard data.count >= 512 else {
            cryptoLogger.error("❌ [OLE2] 文件太小")
            return nil
        }
        
        // 检查魔数
        let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard data.starts(with: Data(ole2Magic)) else {
            cryptoLogger.error("❌ [OLE2] 魔数不匹配")
            return nil
        }
        
        // 读取 Header 中的所有值
        let sectorSizePower = Int(UInt16(data[30]) | (UInt16(data[31]) << 8))
        let sectorSizeValue = 1 << sectorSizePower
        
        let miniSectorSizePower = Int(UInt16(data[32]) | (UInt16(data[33]) << 8))
        let miniSectorSizeValue = 1 << miniSectorSizePower
        
        let numFatSectors = Int(UInt32(data[44]) | (UInt32(data[45]) << 8) | (UInt32(data[46]) << 16) | (UInt32(data[47]) << 24))
        
        let rootEntrySectorValue = Int(UInt32(data[48]) | (UInt32(data[49]) << 8) | (UInt32(data[50]) << 16) | (UInt32(data[51]) << 24))
        
        let miniStreamCutoffValue = Int(UInt32(data[56]) | (UInt32(data[57]) << 8) | (UInt32(data[58]) << 16) | (UInt32(data[59]) << 24))
        
        let firstDifatSector = Int(UInt32(data[68]) | (UInt32(data[69]) << 8) | (UInt32(data[70]) << 16) | (UInt32(data[71]) << 24))
        
        // Header DIFAT (first 109 entries): offset 76
        var difatEntries: [Int] = []
        for i in 0..<109 {
            let offset = 76 + i * 4
            let entry = Int(UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24))
            if entry < 0xFFFFFFFC {
                difatEntries.append(entry)
            }
        }
        
        // 现在初始化存储属性
        self.data = data
        self.sectorSize = sectorSizeValue
        self.miniSectorSize = miniSectorSizeValue
        self.rootEntrySector = rootEntrySectorValue
        self.miniStreamCutoff = miniStreamCutoffValue
        // 临时初始化 difat 和 fat
        self.difat = difatEntries
        self.fat = []
        
        // 打印初始化信息
        cryptoLogger.info("📦 [OLE2] 扇区大小: \(sectorSizeValue) 字节")
        cryptoLogger.info("📦 [OLE2] 迷你扇区大小: \(miniSectorSizeValue) 字节")
        cryptoLogger.info("📦 [OLE2] FAT 扇区数: \(numFatSectors)")
        cryptoLogger.info("📦 [OLE2] 根目录扇区: \(rootEntrySectorValue)")
        cryptoLogger.info("📦 [OLE2] 迷你流阈值: \(miniStreamCutoffValue)")
        
        // 如果有更多的 DIFAT 扇区，读取它们
        if firstDifatSector < 0xFFFFFFFC {
            self.difat = readExtendedDifat(firstSector: firstDifatSector, existingEntries: difatEntries)
        }
        cryptoLogger.info("📦 [OLE2] DIFAT 条目数: \(self.difat.count)")
        
        // 读取 FAT
        var fatEntries: [Int] = []
        for sector in self.difat {
            let sectorOffset = (sector + 1) * sectorSizeValue
            guard sectorOffset + sectorSizeValue <= data.count else { continue }
            for i in 0..<(sectorSizeValue / 4) {
                let offset = sectorOffset + i * 4
                let entry = Int(UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24))
                fatEntries.append(entry)
            }
        }
        self.fat = fatEntries
        cryptoLogger.info("📦 [OLE2] FAT 条目数: \(self.fat.count)")
    }
    
    private func readExtendedDifat(firstSector: Int, existingEntries: [Int]) -> [Int] {
        var entries = existingEntries
        var currentSector = firstSector
        var visited: Set<Int> = []
        
        while currentSector < 0xFFFFFFFC && !visited.contains(currentSector) {
            visited.insert(currentSector)
            let sectorOffset = (currentSector + 1) * sectorSize
            guard sectorOffset + sectorSize <= data.count else { break }
            
            // 读取 127 个 DIFAT 条目和下一个扇区指针
            for i in 0..<127 {
                let offset = sectorOffset + i * 4
                let entry = Int(UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24))
                if entry < 0xFFFFFFFC {
                    entries.append(entry)
                }
            }
            
            // 下一个 DIFAT 扇区
            let nextOffset = sectorOffset + 127 * 4
            currentSector = Int(UInt32(data[nextOffset]) | (UInt32(data[nextOffset + 1]) << 8) | (UInt32(data[nextOffset + 2]) << 16) | (UInt32(data[nextOffset + 3]) << 24))
        }
        
        return entries
    }
    
    func listAllStreams() {
        cryptoLogger.info("📋 [OLE2] 开始列出所有目录项")
        let entries = readDirectoryEntries()
        for (id, entry) in entries.enumerated() {
            let typeName: String
            switch entry.type {
            case .unknown: typeName = "未知"
            case .storage: typeName = "目录"
            case .stream: typeName = "流"
            case .root: typeName = "根目录"
            }
            cryptoLogger.info("📋 [OLE2] [\(id)] 类型: \(typeName), 名称: '\(entry.name)', 大小: \(entry.size), 起始扇区: \(entry.startSector)")
        }
    }
    
    private func readDirectoryEntries() -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        var currentSector = rootEntrySector
        var visited: Set<Int> = []
        
        while currentSector < 0xFFFFFFFC && !visited.contains(currentSector) {
            visited.insert(currentSector)
            let sectorOffset = (currentSector + 1) * sectorSize
            guard sectorOffset + sectorSize <= data.count else { break }
            
            // 每个目录项 128 字节
            // 根据实际文件数据修正的目录项结构：
            // 0x00-0x3F (64 bytes): 名称（UTF-16LE，以空字符结尾）
            // 0x40-0x41 (2 bytes): 名称长度（字符数，不含空字符）
            // 0x42 (1 byte): 类型 (0=空, 1=存储, 2=流, 5=根)
            // 0x43 (1 byte): 颜色标志
            // 0x44-0x47 (4 bytes): 左子节点 ID
            // 0x48-0x4B (4 bytes): 右子节点 ID
            // 0x4C-0x4F (4 bytes): 子节点 ID
            // 0x50-0x5F (16 bytes): CLSID
            // 0x60-0x63 (4 bytes): 用户标志
            // 0x64-0x6B (8 bytes): 创建时间
            // 0x6C-0x73 (8 bytes): 修改时间
            // 0x72-0x75 (4 bytes): 起始扇区
            // 0x76-0x7D (8 bytes): 大小
            
            let entriesPerSector = sectorSize / 128
            for i in 0..<entriesPerSector {
                let offset = sectorOffset + i * 128
                guard offset + 128 <= data.count else { break }
                
                // 读取名称长度（偏移 0x40-0x41，2 字节，字符数）
                let nameLength = Int(UInt16(data[offset + 64]) | (UInt16(data[offset + 65]) << 8))
                if nameLength == 0 {
                    continue // 空目录项
                }
                
                // 读取名称（UTF-16LE 编码，最多 64 字节）
                let nameBytes = data.subdata(in: offset..<(offset + min(nameLength * 2, 64)))
                let name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
                
                // 去除可能的空字符
                let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                
                // 读取类型（偏移 0x42，1 字节）
                let type = DirectoryType(rawValue: data[offset + 66]) ?? .unknown
                
                // 读取左子节点 ID（偏移 0x44-0x47，4 字节）
                let leftID = Int(UInt32(data[offset + 68]) | (UInt32(data[offset + 69]) << 8) | (UInt32(data[offset + 70]) << 16) | (UInt32(data[offset + 71]) << 24))
                
                // 读取右子节点 ID（偏移 0x48-0x4B，4 字节）
                let rightID = Int(UInt32(data[offset + 72]) | (UInt32(data[offset + 73]) << 8) | (UInt32(data[offset + 74]) << 16) | (UInt32(data[offset + 75]) << 24))
                
                // 读取子节点 ID（偏移 0x4C-0x4F，4 字节）
                let childID = Int(UInt32(data[offset + 76]) | (UInt32(data[offset + 77]) << 8) | (UInt32(data[offset + 78]) << 16) | (UInt32(data[offset + 79]) << 24))
                
                // 读取起始扇区（偏移 0x74-0x77，4 字节）
                let startSector = Int(UInt32(data[offset + 116]) | (UInt32(data[offset + 117]) << 8) | (UInt32(data[offset + 118]) << 16) | (UInt32(data[offset + 119]) << 24))
                
                // 读取大小（偏移 0x78-0x7F，8 字节）
                let sizeLow = UInt32(data[offset + 120]) | (UInt32(data[offset + 121]) << 8) | (UInt32(data[offset + 122]) << 16) | (UInt32(data[offset + 123]) << 24)
                let sizeHigh = UInt32(data[offset + 124]) | (UInt32(data[offset + 125]) << 8) | (UInt32(data[offset + 126]) << 16) | (UInt32(data[offset + 127]) << 24)
                let size = Int(sizeHigh) << 32 | Int(sizeLow)
                
                // 调试：打印目录项的完整 128 字节
                let debugData = self.data.subdata(in: offset..<min(offset+128, self.data.count))
                let hexString = debugData.map { String(format: "%02X ", $0) }.joined()
                cryptoLogger.debug("📋 [OLE2] 目录项 \(i) 完整 128 字节: \(hexString)")
                
                entries.append(DirectoryEntry(
                    name: cleanName,
                    type: type,
                    startSector: startSector,
                    size: size,
                    childID: childID,
                    leftID: leftID,
                    rightID: rightID
                ))
            }
            
            // 下一个扇区
            if currentSector < fat.count {
                currentSector = fat[currentSector]
            } else {
                break
            }
        }
        
        return entries
    }
    
    func readStream(name: String) -> Data? {
        let entries = readDirectoryEntries()
        guard let entry = entries.first(where: { $0.name == name && $0.type == .stream }) else {
            return nil
        }
        
        return readStreamData(entry: entry)
    }
    
    private func readStreamData(entry: DirectoryEntry) -> Data {
        if entry.size < miniStreamCutoff {
            // 小流，使用迷你流
            return readMiniStream(entry: entry)
        } else {
            // 大流，使用普通流
            return readNormalStream(entry: entry)
        }
    }
    
    private func readNormalStream(entry: DirectoryEntry) -> Data {
        var streamData = Data()
        var currentSector = entry.startSector
        var bytesRead = 0
        var visited: Set<Int> = []
        
        while currentSector < 0xFFFFFFFC && !visited.contains(currentSector) && bytesRead < entry.size {
            visited.insert(currentSector)
            let sectorOffset = (currentSector + 1) * sectorSize
            guard sectorOffset + sectorSize <= data.count else { break }
            
            let sectorData = data.subdata(in: sectorOffset..<sectorOffset + sectorSize)
            let bytesToAppend = min(sectorSize, entry.size - bytesRead)
            streamData.append(sectorData.prefix(bytesToAppend))
            bytesRead += bytesToAppend
            
            if currentSector < fat.count {
                currentSector = fat[currentSector]
            } else {
                break
            }
        }
        
        return streamData
    }
    
    private func readMiniStream(entry: DirectoryEntry) -> Data {
        // 首先找到根目录项，它包含迷你流的位置
        let entries = readDirectoryEntries()
        guard let rootEntry = entries.first(where: { $0.type == .root }) else {
            cryptoLogger.error("❌ [OLE2] 未找到根目录项")
            return Data()
        }
        
        // 读取迷你流容器
        let miniStream = readNormalStream(entry: rootEntry)
        
        // 从迷你流中读取小流
        var streamData = Data()
        var currentMiniSector = entry.startSector
        var bytesRead = 0
        var visited: Set<Int> = []
        
        while currentMiniSector < 0xFFFFFFFC && !visited.contains(currentMiniSector) && bytesRead < entry.size {
            visited.insert(currentMiniSector)
            let miniOffset = currentMiniSector * miniSectorSize
            guard miniOffset + miniSectorSize <= miniStream.count else { break }
            
            let sectorData = miniStream.subdata(in: miniOffset..<miniOffset + miniSectorSize)
            let bytesToAppend = min(miniSectorSize, entry.size - bytesRead)
            streamData.append(sectorData.prefix(bytesToAppend))
            bytesRead += bytesToAppend
            
            // 迷你流的 FAT 在根目录的某个位置，这里简化处理
            // 实际上需要单独的迷你 FAT，复杂实现
            // 这里我们假设迷你流是连续的
            currentMiniSector += 1
        }
        
        return streamData
    }
}

// MARK: - Data Extension for SHA
extension Data {
    func sha1() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        self.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
    
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
}

// MARK: - String Extension for SHA
extension String {
    func sha1() -> Data {
        guard let data = self.data(using: .utf8) else {
            return Data()
        }
        return data.sha1()
    }
    
    func sha256() -> Data {
        guard let data = self.data(using: .utf8) else {
            return Data()
        }
        return data.sha256()
    }
}
