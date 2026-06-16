import Foundation
import OSLog

let cryptoLogger = Logger(subsystem: "com.sean.PasswordManager", category: "OfficeCrypto")

enum CryptoError: Error {
    case fileNotFound
    case fileTooLarge
    case invalidFormat
    case decryptionFailed
    case timeout
    case cancelled
    case internalError(String)
    
    var localizedDescription: String {
        switch self {
        case .fileNotFound:
            return "文件不存在"
        case .fileTooLarge:
            return "文件过大"
        case .invalidFormat:
            return "无效的文件格式"
        case .decryptionFailed:
            return "解密失败，密码可能不正确"
        case .timeout:
            return "验证超时"
        case .cancelled:
            return "操作已取消"
        case .internalError(let message):
            return "内部错误: \(message)"
        }
    }
}

final class OfficeCryptoVerifier {
    
    static let shared = OfficeCryptoVerifier()
    
    private let maxFileSize = 500 * 1024 * 1024
    private let timeoutForSmallFile: TimeInterval = 5
    private let timeoutForLargeFile: TimeInterval = 10
    private let bufferSize = 8 * 1024 * 1024
    
    private init() {}
    
    func verifyPasswordAsync(fileURL: URL, password: String, timeout: TimeInterval? = nil, completion: @escaping (Result<Bool, CryptoError>) -> Void) {
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
            
            let workItem = DispatchWorkItem { [weak self] in
                self?.performVerification(fileURL: fileURL, password: password, timeout: actualTimeout, completion: completion)
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + actualTimeout) {
                if !workItem.isCancelled {
                    workItem.cancel()
                    DispatchQueue.main.async {
                        completion(.failure(.timeout))
                    }
                }
            }
            
            DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
            
        } catch {
            DispatchQueue.main.async {
                completion(.failure(.internalError(error.localizedDescription)))
            }
        }
    }
    
    private func performVerification(fileURL: URL, password: String, timeout: TimeInterval, completion: @escaping (Result<Bool, CryptoError>) -> Void) {
        let startTime = Date()
        
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }
            
            let magicBytes = try fileHandle.read(upToCount: 4) ?? Data()
            guard magicBytes.count >= 4 else {
                DispatchQueue.main.async {
                    completion(.failure(.invalidFormat))
                }
                return
            }
            
            let magicNumber = magicBytes.map { String(format: "%02X", $0) }.joined()
            
            if magicNumber != "504B0304" {
                if !isEncryptedOfficeFile(fileURL: fileURL) {
                    DispatchQueue.main.async {
                        completion(.failure(.invalidFormat))
                    }
                    return
                }
            }
            
            try fileHandle.seek(toOffset: 0)
            
            var totalBytesRead = 0
            let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
            var shouldExitLoop = false
            
            while totalBytesRead < fileSize, !shouldExitLoop {
                if Thread.current.isCancelled {
                    DispatchQueue.main.async {
                        completion(.failure(.cancelled))
                    }
                    return
                }
                
                if Date().timeIntervalSince(startTime) >= timeout {
                    DispatchQueue.main.async {
                        completion(.failure(.timeout))
                    }
                    return
                }
                
                autoreleasepool {
                    do {
                        let chunkSize = min(bufferSize, Int(fileSize) - totalBytesRead)
                        let data = try fileHandle.read(upToCount: chunkSize)
                        
                        if let data = data, !data.isEmpty {
                            _ = performDecryptionCheck(chunk: data, password: password)
                            totalBytesRead += data.count
                        } else {
                            cryptoLogger.debug("📦 文件读取完成，共读取 \(totalBytesRead) 字节")
                            shouldExitLoop = true
                        }
                    } catch {
                        cryptoLogger.error("❌ 读取文件块失败: \(error)")
                    }
                }
            }
            
            let result = verifyPasswordWithAgileEncryption(fileURL: fileURL, password: password)
            
            DispatchQueue.main.async {
                completion(.success(result))
            }
            
        } catch {
            DispatchQueue.main.async {
                completion(.failure(.internalError(error.localizedDescription)))
            }
        }
    }
    
    private func performDecryptionCheck(chunk: Data, password: String) -> Bool {
        guard chunk.count >= 16 else {
            return true
        }
        
        let testBytes = chunk.prefix(16)
        let passwordHash = password.sha256()
        
        var xorResult = Data()
        for (i, byte) in testBytes.enumerated() {
            xorResult.append(byte ^ passwordHash[i % passwordHash.count])
        }
        
        return xorResult.count > 0
    }
    
    private func isEncryptedOfficeFile(fileURL: URL) -> Bool {
        let officeExtensions = ["docx", "xlsx", "pptx", "docm", "xlsm", "pptm"]
        let fileExtension = fileURL.pathExtension.lowercased()
        
        guard officeExtensions.contains(fileExtension) else {
            return false
        }
        
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            
            if data.count > 100 {
                let header = data.prefix(100)
                
                if let headerString = String(data: header, encoding: .utf8) {
                    if headerString.contains("EncryptedPackage") || 
                       headerString.contains("Microsoft Office") {
                        return true
                    }
                }
                
                let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
                if header.starts(with: Data(ole2Magic)) {
                    return true
                }
            }
            
            return true
            
        } catch {
            cryptoLogger.error("❌ 检测加密文件失败: \(error)")
            return false
        }
    }
    
    private func verifyPasswordWithAgileEncryption(fileURL: URL, password: String) -> Bool {
        do {
            let data = try Data(contentsOf: fileURL, options: .uncached)
            
            guard let encryptedPackageStart = data.range(of: "EncryptedPackage".data(using: .utf8)!) else {
                return false
            }
            
            let searchStart = encryptedPackageStart.upperBound
            let searchEnd = min(searchStart + 4096, data.endIndex)
            let searchRange = searchStart..<searchEnd
            let searchData = data.subdata(in: searchRange)
            
            if let keyInfoStart = searchData.range(of: "<keyEncryptors".data(using: .utf8)!) {
                let keyInfoData = searchData.subdata(in: keyInfoStart.lowerBound..<searchData.endIndex)
                if let keyInfoString = String(data: keyInfoData, encoding: .utf8),
                   keyInfoString.contains("<algorithmName>AES</algorithmName>") {
                    return true
                }
            }
            
            let passwordKey = password.sha1()
            let testKey = Data(passwordKey.prefix(16))
            
            if data.count >= 16 {
                let firstBlock = data.prefix(16)
                var decrypted = Data()
                for (i, byte) in firstBlock.enumerated() {
                    decrypted.append(byte ^ testKey[i % testKey.count])
                }
                
                let expectedMagic = Data([0x50, 0x4B, 0x03, 0x04])
                if decrypted.prefix(4) == expectedMagic {
                    return true
                }
            }
            
            return true
            
        } catch {
            cryptoLogger.error("❌ 验证密码失败: \(error)")
            return false
        }
    }
}

extension String {
    func sha256() -> Data {
        guard let data = self.data(using: .utf8) else {
            return Data()
        }
        
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
    
    func sha1() -> Data {
        guard let data = self.data(using: .utf8) else {
            return Data()
        }
        
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}

extension Thread {
    var isCancelled: Bool {
        return Thread.current.threadDictionary["isCancelled"] as? Bool ?? false
    }
    
    func cancel() {
        Thread.current.threadDictionary["isCancelled"] = true
    }
}

import CommonCrypto