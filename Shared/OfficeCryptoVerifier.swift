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
    
    func isFileEncrypted(fileURL: URL) -> Bool {
        cryptoLogger.info("🔍 [加密检测] 开始检测文件是否加密")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cryptoLogger.warning("⚠️ [加密检测] 文件不存在")
            return false
        }
        
        do {
            let fileData = try Data(contentsOf: fileURL, options: .uncached)
            cryptoLogger.debug("🔍 [加密检测] 文件大小: \(fileData.count) 字节")
            
            if isOLE2Format(data: fileData) {
                cryptoLogger.info("🔍 [加密检测] 识别为 OLE2 复合文档")
                
                if let ole2Parser = OLE2Parser(data: fileData) {
                    if ole2Parser.readStream(name: "EncryptionInfo") != nil {
                        cryptoLogger.info("✅ [加密检测] OLE2文件存在 EncryptionInfo 流，判定为加密文件")
                        return true
                    }
                }
                cryptoLogger.info("❌ [加密检测] OLE2文件未找到 EncryptionInfo 流，判定为未加密")
                return false
            }
            
            if let _ = fileData.range(of: "EncryptedPackage".data(using: .utf8)!) {
                cryptoLogger.info("✅ [加密检测] OOXML文件存在 EncryptedPackage 标记，判定为加密文件")
                return true
            }
            
            cryptoLogger.info("❌ [加密检测] 文件未找到加密标记，判定为未加密")
            return false
            
        } catch {
            cryptoLogger.error("❌ [加密检测] 文件读取失败: \(error)")
            return false
        }
    }
    
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
            
            cryptoLogger.debug("🔐 [密码验证] 所有验证方法均失败")
            return .success(false)
            
        } catch {
            cryptoLogger.error("❌ [密码验证] 文件读取失败: \(error)")
            return .failure(.internalError(error.localizedDescription))
        }
    }
    
    private func findEncryptionInfo(in data: Data, before endOffset: Int) -> Data? {
        let searchRange = max(0, endOffset - 8192)..<endOffset
        let searchData = data.subdata(in: searchRange)
        
        if let xmlString = String(data: searchData, encoding: .utf8) {
            if xmlString.contains("<encryption") || xmlString.contains("keyData") || xmlString.contains("encryptedKey") {
                cryptoLogger.debug("🔐 [密码验证] 找到加密 XML")
                return searchData
            }
        }
        
        for offset in stride(from: searchData.count - 100, through: 0, by: -1) {
            if offset + 8 <= searchData.count {
                let versionMajor = UInt16(searchData[offset]) | (UInt16(searchData[offset + 1]) << 8)
                let versionMinor = UInt16(searchData[offset + 2]) | (UInt16(searchData[offset + 3]) << 8)
                
                if versionMajor == 4 && versionMinor == 4 {
                    cryptoLogger.debug("🔐 [密码验证] 在偏移 \(offset) 找到 Agile Encryption 标记")
                    let infoStart = searchRange.lowerBound + offset
                    return data.subdata(in: infoStart..<endOffset)
                }
                
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
        
        guard encryptionInfo.count > 8 else {
            cryptoLogger.debug("🔐 [Agile] EncryptionInfo 数据太短")
            return nil
        }
        
        let xmlData = encryptionInfo.subdata(in: 8..<encryptionInfo.count)
        if let xmlString = String(data: xmlData, encoding: .utf8) {
            return verifyAgileXML(xmlString: xmlString, password: password)
        }
        
        return nil
    }
    
    private func verifyAgileXML(xmlString: String, password: String) -> Result<Bool, CryptoError>? {
        cryptoLogger.debug("🔐 [Agile XML] 开始解析 XML")
        cryptoLogger.debug("🔐 [Agile XML] XML 长度: \(xmlString.count)")
        
        // Agile Encryption XML 格式：
        // <p:encryptedKey spinCount="..." saltValue="..." encryptedVerifierHashInput="..." encryptedVerifierHashValue="..." encryptedKeyValue="..."/>
        // 所有值都是 encryptedKey 标签的属性
        
        guard let spinCountStr = extractTagAttribute(xmlString, tag: "encryptedKey", attribute: "spinCount"),
              let spinCount = Int(spinCountStr) else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 spinCount")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] spinCount: \(spinCount)")
        
        guard let passwordSaltBase64 = extractTagAttribute(xmlString, tag: "encryptedKey", attribute: "saltValue"),
              let passwordSalt = Data(base64Encoded: passwordSaltBase64) else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 saltValue")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 saltValue，长度: \(passwordSalt.count)")
        
        guard let encryptedKeyValueBase64 = extractTagAttribute(xmlString, tag: "encryptedKey", attribute: "encryptedKeyValue"),
              let encryptedKeyValue = Data(base64Encoded: encryptedKeyValueBase64) else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 encryptedKeyValue")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 encryptedKeyValue，长度: \(encryptedKeyValue.count)")
        
        guard let encryptedVerifierHashInputBase64 = extractTagAttribute(xmlString, tag: "encryptedKey", attribute: "encryptedVerifierHashInput"),
              let encryptedVerifierHashInput = Data(base64Encoded: encryptedVerifierHashInputBase64) else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 encryptedVerifierHashInput")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 encryptedVerifierHashInput，长度: \(encryptedVerifierHashInput.count)")
        
        guard let encryptedVerifierHashValueBase64 = extractTagAttribute(xmlString, tag: "encryptedKey", attribute: "encryptedVerifierHashValue"),
              let encryptedVerifierHashValue = Data(base64Encoded: encryptedVerifierHashValueBase64) else {
            cryptoLogger.debug("🔐 [Agile XML] 未找到 encryptedVerifierHashValue")
            return nil
        }
        cryptoLogger.debug("🔐 [Agile XML] 找到 encryptedVerifierHashValue，长度: \(encryptedVerifierHashValue.count)")
        
        let hashAlgorithm = extractTagAttribute(xmlString, tag: "encryptedKey", attribute: "hashAlgorithm") ?? "SHA1"
        cryptoLogger.debug("🔐 [Agile XML] hashAlgorithm: \(hashAlgorithm)")
        
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
    
    private func extractTagAttribute(_ xml: String, tag: String, attribute: String) -> String? {
        let tagPattern = "<[^>]*\(tag)[^>]+>"
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
    
    private let kVerifierInputBlock: [UInt8] = [0xfe, 0xa7, 0xd2, 0x76, 0x3b, 0x4b, 0x9e, 0x79]
    private let kHashedVerifierBlock: [UInt8] = [0xd7, 0xaa, 0x0f, 0x6d, 0x30, 0x61, 0x34, 0x4e]
    private let kCryptoKeyBlock: [UInt8] = [0x14, 0x6e, 0x0b, 0xe7, 0xab, 0xac, 0xd0, 0xd6]
    
    private func verifyPassword(password: String,
                                salt: Data,
                                spinCount: Int,
                                hashAlgorithm: String,
                                encryptedKeyValue: Data,
                                encryptedVerifierHashInput: Data,
                                encryptedVerifierHashValue: Data) -> Bool {
        
        cryptoLogger.debug("🔐 [密码验证] 开始 Agile Encryption 密码验证")
        cryptoLogger.info("🔐 [密码验证] 验证的密码: \(password)")
        cryptoLogger.debug("🔐 [密码验证] 密码长度: \(password.count)")
        cryptoLogger.debug("🔐 [密码验证] Salt 长度: \(salt.count)")
        cryptoLogger.debug("🔐 [密码验证] SpinCount: \(spinCount)")
        cryptoLogger.debug("🔐 [密码验证] Hash算法: \(hashAlgorithm)")
        
        // Office 使用 UTF-16LE 编码的密码
        let passwordData = password.data(using: .utf16LittleEndian)!
        
        // Step 1: ECMA-376 自定义迭代哈希 (不是 PBKDF2)
        // H_0 = H(salt + password)
        // H_n = H(iterator + H_n-1)
        let hashSize = hashAlgorithm.lowercased().contains("sha512") ? 64 :
                       hashAlgorithm.lowercased().contains("sha256") ? 32 : 20
        let pwHash = hashPassword(passwordData: passwordData,
                                  salt: salt,
                                  spinCount: spinCount,
                                  hashAlgorithm: hashAlgorithm)
        
        cryptoLogger.debug("🔐 [密码验证] pwHash 长度: \(pwHash.count)")
        
        guard !pwHash.isEmpty else {
            cryptoLogger.error("❌ [密码验证] 哈希派生失败")
            return false
        }
        
        // Step 2: 使用 kVerifierInputBlock 生成解密密钥和IV，解密 verifierHashInput
        let keySize = 16
        let verifierKey = generateKey(pwHash: pwHash, hashAlgorithm: hashAlgorithm, blockKey: kVerifierInputBlock, keySize: keySize)
        
        cryptoLogger.debug("🔐 [密码验证] verifierKey 长度: \(verifierKey.count)")
        
        // IV = salt 原文（msoffcrypto 实现直接用 salt 作为 AES-CBC IV）
        let iv = salt
        
        cryptoLogger.debug("🔐 [密码验证] IV 长度: \(iv.count)")
        
        // 解密 encryptedVerifierHashInput（无 PKCS7 padding，verifier 是随机 16 字节）
        let decryptedVerifier = aesDecrypt(
            data: encryptedVerifierHashInput,
            key: verifierKey,
            iv: iv
        )
        
        cryptoLogger.debug("🔐 [密码验证] 解密后的 verifier 长度: \(decryptedVerifier?.count ?? 0)")
        if let ver = decryptedVerifier {
            cryptoLogger.debug("🔐 [密码验证] 解密后的 verifier: \(ver.map { String(format: "%02X", $0) }.joined())")
        }
        
        guard let verifier = decryptedVerifier, verifier.count == 16 else {
            cryptoLogger.error("❌ [密码验证] 解密 verifierHashInput 失败（需要 16 字节）")
            return false
        }
        
        // Step 3: 计算 verifier 的哈希值
        let verifierHash = hashData(data: verifier, algorithm: hashAlgorithm)
        
        cryptoLogger.debug("🔐 [密码验证] verifierHash 长度: \(verifierHash.count)")
        cryptoLogger.debug("🔐 [密码验证] verifierHash: \(verifierHash.map { String(format: "%02X", $0) }.joined())")
        
        // Step 4: 使用 kHashedVerifierBlock 生成解密密钥和IV，解密 verifierHashValue
        let hashKey = generateKey(pwHash: pwHash, hashAlgorithm: hashAlgorithm, blockKey: kHashedVerifierBlock, keySize: keySize)
        
        cryptoLogger.debug("🔐 [密码验证] hashKey 长度: \(hashKey.count)")
        
        // 解密 encryptedVerifierHashValue（同样用 salt 原文作 IV，无 PKCS7 padding）
        let decryptedVerifierHash = aesDecrypt(
            data: encryptedVerifierHashValue,
            key: hashKey,
            iv: iv
        )
        
        cryptoLogger.debug("🔐 [密码验证] 解密后的 verifierHash 长度: \(decryptedVerifierHash?.count ?? 0)")
        if let vh = decryptedVerifierHash {
            cryptoLogger.debug("🔐 [密码验证] 解密后的 verifierHash: \(vh.map { String(format: "%02X", $0) }.joined())")
        }
        
        guard let expectedVerifierHash = decryptedVerifierHash, !expectedVerifierHash.isEmpty else {
            cryptoLogger.error("❌ [密码验证] 解密 verifierHashValue 失败")
            return false
        }
        
        // Step 5: 截取期望的哈希值（去除填充）
        let expectedHashTrimmed = expectedVerifierHash.prefix(hashSize)
        
        cryptoLogger.debug("🔐 [密码验证] 计算的哈希: \(verifierHash.map { String(format: "%02X", $0) }.joined())")
        cryptoLogger.debug("🔐 [密码验证] 期望的哈希: \(expectedHashTrimmed.map { String(format: "%02X", $0) }.joined())")
        
        let isValid = verifierHash == expectedHashTrimmed
        
        cryptoLogger.debug("🔐 [密码验证] 验证结果: \(isValid)")
        
        return isValid
    }
    
    private func hashPassword(passwordData: Data, salt: Data, spinCount: Int, hashAlgorithm: String) -> Data {
        // ECMA-376 2.3.4.11:
        // H_0 = H(salt + password)
        // H_n = H(iterator + H_n-1)，iterator 是 32 位无符号整数，从 0 到 spinCount-1
        
        let initialData = salt + passwordData
        var currentHash = hashData(data: initialData, algorithm: hashAlgorithm)
        
        for iterator in 0..<spinCount {
            var iteratorBytes = [UInt8](repeating: 0, count: 4)
            iteratorBytes[0] = UInt8(iterator & 0xFF)
            iteratorBytes[1] = UInt8((iterator >> 8) & 0xFF)
            iteratorBytes[2] = UInt8((iterator >> 16) & 0xFF)
            iteratorBytes[3] = UInt8((iterator >> 24) & 0xFF)
            
            let combined = Data(iteratorBytes) + currentHash
            currentHash = hashData(data: combined, algorithm: hashAlgorithm)
        }
        
        return currentHash
    }
    
    private func generateKey(pwHash: Data, hashAlgorithm: String, blockKey: [UInt8], keySize: Int) -> Data {
        // ECMA-376 2.3.4.11:
        // H_final = H(H_n + blockKey)
        // 如果结果小于 keySize，用 0x36 填充；如果大于，截断
        
        let combined = pwHash + Data(blockKey)
        let hFinal = hashData(data: combined, algorithm: hashAlgorithm)
        
        var result = Data()
        if hFinal.count >= keySize {
            result = hFinal.prefix(keySize)
        } else {
            result = hFinal
            result.append(Data(repeating: 0x36, count: keySize - hFinal.count))
        }
        
        return result
    }
    
    private func generateIv(hashAlgorithm: String, salt: Data, blockKey: [UInt8]?, blockSize: Int) -> Data {
        // ECMA-376 2.3.4.12:
        // 如果提供了 blockKey: IV = H(KeySalt + blockKey)
        // 如果没有提供 blockKey: IV = KeySalt
        // 如果 IV 长度小于 blockSize，用 0x36 填充；如果大于，截断
        
        var iv: Data
        
        if let blockKey = blockKey {
            let combined = salt + Data(blockKey)
            iv = hashData(data: combined, algorithm: hashAlgorithm)
        } else {
            iv = salt
        }
        
        var result = Data()
        if iv.count >= blockSize {
            result = iv.prefix(blockSize)
        } else {
            result = iv
            result.append(Data(repeating: 0x36, count: blockSize - iv.count))
        }
        
        return result
    }
    
    private func aesDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = data.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted: size_t = 0
        
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0),
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
        
        if let ole2Parser = OLE2Parser(data: data) {
            cryptoLogger.info("🔐 [OLE2] OLE2 解析器初始化成功")
            
            ole2Parser.listAllStreams()
            
            if let encryptionInfo = ole2Parser.readStream(name: "EncryptionInfo") {
                cryptoLogger.info("🔐 [OLE2] 找到 EncryptionInfo 流，长度: \(encryptionInfo.count)")
                cryptoLogger.debug("🔐 [OLE2] EncryptionInfo 前 32 字节: \(encryptionInfo.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " "))")
                
                if let result = verifyEncryptionInfo(encryptionInfo, password: password) {
                    return result
                }
            } else {
                cryptoLogger.warning("🔐 [OLE2] 未找到 EncryptionInfo 流")
            }
        } else {
            cryptoLogger.warning("🔐 [OLE2] OLE2 解析器初始化失败")
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
        
        // 解析版本和标志
        let versionMajor = UInt16(encryptionInfo[0]) | (UInt16(encryptionInfo[1]) << 8)
        let versionMinor = UInt16(encryptionInfo[2]) | (UInt16(encryptionInfo[3]) << 8)
        let flags = UInt32(encryptionInfo[4]) | (UInt32(encryptionInfo[5]) << 8) | (UInt32(encryptionInfo[6]) << 16) | (UInt32(encryptionInfo[7]) << 24)
        
        cryptoLogger.info("🔐 [EncryptionInfo] 版本: \(versionMajor).\(versionMinor), Flags: \(String(format: "%08X", flags))")
        
        // Agile Encryption: version 4.4
        // 格式: versionMajor(2) + versionMinor(2) + flags(4) + xmlData
        if versionMajor == 4 && versionMinor == 4 {
            cryptoLogger.info("🔐 [EncryptionInfo] 识别为 Agile Encryption 4.4")
            let xmlData = encryptionInfo.subdata(in: 8..<encryptionInfo.count)
            if let xmlString = String(data: xmlData, encoding: .utf8) {
                cryptoLogger.debug("🔐 [EncryptionInfo] XML 长度: \(xmlString.count)")
                cryptoLogger.debug("🔐 [EncryptionInfo] XML 前 100 字符: \(xmlString.prefix(100))")
                return verifyAgileXML(xmlString: xmlString, password: password)
            }
        }
        
        // Standard Encryption: version 2.2, 3.2, 4.2
        if (versionMajor >= 2 && versionMajor <= 4) && versionMinor == 2 {
            cryptoLogger.info("🔐 [EncryptionInfo] 识别为 Standard Encryption")
            return verifyStandardBinaryEncryption(encryptionInfo: encryptionInfo, password: password)
        }
        
        // 检查是否为纯 XML 格式（无二进制头部）
        if let xmlString = String(data: encryptionInfo, encoding: .utf8) {
            if xmlString.hasPrefix("<?xml") || xmlString.hasPrefix("<encryption") {
                cryptoLogger.info("🔐 [EncryptionInfo] 识别为纯 XML 格式")
                return verifyAgileXML(xmlString: xmlString, password: password)
            }
        }
        
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
