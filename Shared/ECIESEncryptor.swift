import Foundation
import OSLog
import Security
import CommonCrypto

let eciesLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "ECIES")

final class ECIESEncryptor {
    
    static let shared = ECIESEncryptor()
    
    private init() {}
    
    private func x509SpkiToRawEcPoint(x509Data: Data) -> Data? {
        guard x509Data.count == 91 else { return nil }
        let rawEcPoint = x509Data.subdata(in: 26..<91)
        guard rawEcPoint.count == 65 && rawEcPoint[0] == 0x04 else { return nil }
        return rawEcPoint
    }
    
    private func rawEcPointToX509Spki(rawEcPoint: Data) -> Data? {
        guard rawEcPoint.count == 65 && rawEcPoint[0] == 0x04 else { return nil }
        let header: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
        ]
        return Data(header) + rawEcPoint
    }
    
    func encrypt(data: String, publicKeyStr: String) -> String? {
        guard let publicKeyData = Data(base64Encoded: publicKeyStr),
              let passwordData = data.data(using: .utf8) else {
            eciesLogger.error("❌ [ECIES] 公钥Base64解码失败或数据编码失败")
            return nil
        }
        
        eciesLogger.info("📦 [ECIES] 公钥数据长度: \(publicKeyData.count)")
        
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeEC,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256
        ]
        
        var error: Unmanaged<CFError>?
        var serverPublicKey: SecKey?
        
        if let rawEcPoint = x509SpkiToRawEcPoint(x509Data: publicKeyData) {
            eciesLogger.info("✅ [ECIES] X.509转原始EC点成功，长度: \(rawEcPoint.count)")
            serverPublicKey = SecKeyCreateWithData(rawEcPoint as CFData, attributes as CFDictionary, &error)
        }
        
        if serverPublicKey == nil {
            eciesLogger.info("📦 [ECIES] 尝试直接使用原始公钥数据")
            serverPublicKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, &error)
        }
        
        guard let key = serverPublicKey else {
            eciesLogger.error("❌ [ECIES] 创建SecKey公钥失败: \(error?.takeRetainedValue().localizedDescription ?? "未知错误")")
            return nil
        }
        serverPublicKey = key
        
        eciesLogger.info("✅ [ECIES] SecKey公钥创建成功")
        
        guard let clientPrivateKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeEC,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false
        ] as CFDictionary, &error) else {
            eciesLogger.error("❌ [ECIES] 生成临时密钥对失败")
            return nil
        }
        
        guard let clientPublicKey = SecKeyCopyPublicKey(clientPrivateKey) else {
            eciesLogger.error("❌ [ECIES] 获取临时公钥失败")
            return nil
        }
        
        eciesLogger.info("✅ [ECIES] 临时密钥对生成成功")
        
        guard let tempPublicKeyData = SecKeyCopyExternalRepresentation(clientPublicKey, &error) as Data? else {
            eciesLogger.error("❌ [ECIES] 获取临时公钥外部表示失败")
            return nil
        }
        
        eciesLogger.info("✅ [ECIES] 临时公钥外部表示获取成功，长度: \(tempPublicKeyData.count)")
        
        guard let x509TempPublicKey = rawEcPointToX509Spki(rawEcPoint: tempPublicKeyData) else {
            eciesLogger.error("❌ [ECIES] 原始EC点转X.509格式失败")
            return nil
        }
        
        eciesLogger.info("✅ [ECIES] 临时公钥转换为X.509格式成功，长度: \(x509TempPublicKey.count)")
        
        guard let sharedSecret = SecKeyCopyKeyExchangeResult(
            clientPrivateKey,
            SecKeyAlgorithm.ecdhKeyExchangeStandard,
            key,
            [:] as CFDictionary,
            &error
        ) as Data? else {
            eciesLogger.error("❌ [ECIES] ECDH密钥协商失败")
            return nil
        }
        
        eciesLogger.info("✅ [ECIES] ECDH密钥协商成功")
        
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256((sharedSecret as NSData).bytes, CC_LONG(sharedSecret.count), &digest)
        let aesKeyData = Data(digest)
        
        eciesLogger.info("✅ [ECIES] SHA256派生AES密钥成功")
        
        var iv = Data(count: kCCBlockSizeAES128)
        let ivStatus = iv.withUnsafeMutableBytes { ivBytes in
            SecRandomCopyBytes(kSecRandomDefault, kCCBlockSizeAES128, ivBytes.baseAddress!)
        }
        
        guard ivStatus == errSecSuccess else {
            eciesLogger.error("❌ [ECIES] 生成IV失败")
            return nil
        }
        
        eciesLogger.info("✅ [ECIES] 生成随机IV成功")
        
        let bufferSize = passwordData.count + kCCBlockSizeAES128
        var cipherData = Data(count: bufferSize)
        
        var numBytesEncrypted = 0
        let cryptStatus = cipherData.withUnsafeMutableBytes { cipherBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                iv.withUnsafeBytes { ivBytes in
                    aesKeyData.withUnsafeBytes { keyBytes in
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, aesKeyData.count,
                                ivBytes.baseAddress,
                                passwordBytes.baseAddress, passwordData.count,
                                cipherBytes.baseAddress, bufferSize,
                                &numBytesEncrypted)
                    }
                }
            }
        }
        
        guard cryptStatus == kCCSuccess else {
            eciesLogger.error("❌ [ECIES] AES加密失败: \(cryptStatus)")
            return nil
        }
        
        cipherData = cipherData.prefix(numBytesEncrypted)
        eciesLogger.info("✅ [ECIES] AES加密成功")
        
        var resultData = Data()
        
        let pubKeyLen = UInt32(x509TempPublicKey.count).bigEndian
        resultData.append(contentsOf: withUnsafeBytes(of: pubKeyLen) { Array($0) })
        
        resultData.append(x509TempPublicKey)
        resultData.append(iv)
        resultData.append(cipherData)
        
        eciesLogger.info("✅ [ECIES] 加密完成")
        return resultData.base64EncodedString()
    }
}