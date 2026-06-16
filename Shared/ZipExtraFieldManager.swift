import Foundation
import OSLog

let zipLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "ZipExtraField")

final class ZipExtraFieldManager {
    
    static let shared = ZipExtraFieldManager()
    
    private let magic = "WPPM".data(using: .ascii)!
    private let minimumMarkerSize = 15
    private let searchBufferSize = 1024
    
    private enum MetadataType: UInt8 {
        case password = 0x01
        case uid = 0x02
        case keyVersion = 0x03
    }
    
    private init() {}
    
    func readMetadata(from fileURL: URL, type: UInt8) -> String? {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { fileHandle.closeFile() }
            
            let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
            zipLogger.debug("📦 [读取元数据] 文件名: \(fileURL.lastPathComponent)")
            zipLogger.debug("📦 [读取元数据] 文件大小: \(fileSize) 字节")
            
            if fileSize < Int64(minimumMarkerSize) {
                zipLogger.debug("📦 [读取元数据] 文件过小，无法包含 WPPM 标记")
                return nil
            }
            
            let startOffset = max(0, fileSize - Int64(searchBufferSize))
            zipLogger.debug("📦 [读取元数据] 搜索起始偏移: \(startOffset)")
            zipLogger.debug("📦 [读取元数据] 搜索缓冲区大小: \(self.searchBufferSize) 字节")
            
            try fileHandle.seek(toOffset: UInt64(startOffset))
            
            guard let buffer = try fileHandle.readToEnd() else {
                zipLogger.debug("📦 [读取元数据] 读取文件尾部失败")
                return nil
            }
            
            zipLogger.debug("📦 [读取元数据] 实际读取缓冲区大小: \(buffer.count) 字节")
            zipLogger.debug("📦 [读取元数据] 文件尾部十六进制: \(buffer.hexDescriptionShort)")
            
            let result = searchAndParseMarker(in: buffer, expectedType: type, fileSize: fileSize, startOffset: startOffset)
            
            if let result = result {
                zipLogger.debug("✅ [读取元数据] 成功读取类型 0x\(String(format: "%02X", type)) 的元数据: \(result)")
            } else {
                zipLogger.debug("❌ [读取元数据] 未找到类型 0x\(String(format: "%02X", type)) 的元数据")
            }
            
            return result
            
        } catch {
            zipLogger.error("❌ [读取元数据] 读取失败: \(error, privacy: .public)")
            return nil
        }
    }
    
    func readUid(from fileURL: URL) -> String? {
        return readMetadata(from: fileURL, type: MetadataType.uid.rawValue)
    }
    
    func readPassword(from fileURL: URL) -> String? {
        return readMetadata(from: fileURL, type: MetadataType.password.rawValue)
    }
    
    func readKeyVersion(from fileURL: URL) -> String? {
        return readMetadata(from: fileURL, type: MetadataType.keyVersion.rawValue)
    }
    
    private func searchAndParseMarker(in buffer: Data, expectedType: UInt8, fileSize: Int64, startOffset: Int64) -> String? {
        let signatureLength = magic.count
        
        for i in (0...buffer.count - signatureLength).reversed() {
            let slice = buffer.subdata(in: i..<i+signatureLength)
            if slice == magic {
                let absolutePosition = startOffset + Int64(i)
                if let result = parseMarker(at: absolutePosition, in: buffer, relativeOffset: i, expectedType: expectedType) {
                    return result
                }
                zipLogger.debug("🔍 [搜索标记] 类型不匹配，继续向前搜索，当前偏移: \(i)")
            }
        }
        
        return nil
    }
    
    private func parseMarker(at absolutePosition: Int64, in buffer: Data, relativeOffset: Int, expectedType: UInt8) -> String? {
        let remainingLength = buffer.count - relativeOffset
        if remainingLength < minimumMarkerSize {
            zipLogger.debug("📦 剩余长度不足: \(remainingLength) < \(self.minimumMarkerSize)")
            return nil
        }
        
        let magicData = buffer.subdata(in: relativeOffset..<relativeOffset+4)
        let magicString = String(data: magicData, encoding: .ascii) ?? "未知"
        zipLogger.debug("🔍 [解析标记] Magic: \(magicString) (\(magicData.hexDescription))")
        
        guard magicString == "WPPM" else {
            zipLogger.debug("❌ Magic 不匹配: 期望 WPPM，实际 \(magicString)")
            return nil
        }
        
        let versionData = buffer.subdata(in: relativeOffset+4..<relativeOffset+6)
        let version = (Int(versionData[1]) << 8) | Int(versionData[0])
        zipLogger.debug("🔍 [解析标记] Version: \(version) (\(versionData.hexDescription))")
        
        let typeByte = buffer[relativeOffset+6]
        let typeName = typeNameFromByte(typeByte)
        zipLogger.debug("🔍 [解析标记] Type: 0x\(String(format: "%02X", typeByte)) (\(typeName))")
        
        if typeByte != expectedType {
            zipLogger.debug("🔍 [解析标记] Type 不匹配: 期望 0x\(String(format: "%02X", expectedType)) (\(self.typeNameFromByte(expectedType)))，实际 0x\(String(format: "%02X", typeByte)) (\(typeName))，继续向前搜索")
            return nil
        }
        
        let lengthBytes = buffer.subdata(in: relativeOffset+7..<relativeOffset+11)
        let dataLength = byteArrayToIntLittleEndian(lengthBytes)
        zipLogger.debug("🔍 [解析标记] Length: \(dataLength) (\(lengthBytes.hexDescription))")
        
        let totalMarkerSize = 11 + dataLength + 4
        if relativeOffset + totalMarkerSize > buffer.count {
            zipLogger.debug("❌ 标记大小超出缓冲区: 所需 \(totalMarkerSize)，剩余 \(remainingLength)")
            return nil
        }
        
        let contentData = buffer.subdata(in: relativeOffset+11..<relativeOffset+11+dataLength)
        let contentString = String(data: contentData, encoding: .utf8) ?? "无法解码"
        zipLogger.debug("🔍 [解析标记] Content: \(contentString) (\(contentData.count) 字节)")
        
        let expectedCrc32 = buffer.subdata(in: relativeOffset+11+dataLength..<relativeOffset+11+dataLength+4)
        let calculatedCrc32 = calculateCRC32(magicData + versionData + Data([typeByte]) + lengthBytes + contentData)
        zipLogger.debug("🔍 [解析标记] Expected CRC32: \(expectedCrc32.hexDescription)")
        zipLogger.debug("🔍 [解析标记] Calculated CRC32: \(calculatedCrc32.hexDescription)")
        
        guard expectedCrc32 == calculatedCrc32 else {
            zipLogger.debug("❌ CRC32 校验失败")
            return nil
        }
        
        zipLogger.debug("✅ 标记解析成功，绝对位置: \(absolutePosition)")
        return contentString
    }
    
    private func typeNameFromByte(_ type: UInt8) -> String {
        switch type {
        case MetadataType.password.rawValue:
            return "PASSWORD"
        case MetadataType.uid.rawValue:
            return "UID"
        case MetadataType.keyVersion.rawValue:
            return "KEY_VERSION"
        default:
            return "UNKNOWN(0x\(String(format: "%02X", type)))"
        }
    }
    
    func writeMetadata(to fileURL: URL, uid: String?, password: String?, keyVersion: String) -> Bool {
        do {
            try removeOldWppmMarkers(from: fileURL)
            
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { fileHandle.closeFile() }
            
            fileHandle.seekToEndOfFile()
            
            if let uid = uid {
                let uidMarker = buildMarker(type: MetadataType.uid.rawValue, data: uid)
                fileHandle.write(uidMarker)
                zipLogger.debug("✅ 写入 UID 标记")
            }
            
            if let password = password {
                let passwordMarker = buildMarker(type: MetadataType.password.rawValue, data: password)
                fileHandle.write(passwordMarker)
                zipLogger.debug("✅ 写入 PASSWORD 标记")
            }
            
            let keyVersionMarker = buildMarker(type: MetadataType.keyVersion.rawValue, data: keyVersion)
            fileHandle.write(keyVersionMarker)
            zipLogger.debug("✅ 写入 KEY_VERSION 标记")
            
            return true
        } catch {
            zipLogger.error("❌ 写入元数据失败: \(error, privacy: .public)")
            return false
        }
    }
    
    private func buildMarker(type: UInt8, data: String) -> Data {
        let version = Data([0x01, 0x00])
        let typeByte = Data([type])
        let dataBytes = data.data(using: .utf8)!
        let length = intToByteArrayLittleEndian(dataBytes.count)
        let crc32 = calculateCRC32(magic + version + typeByte + length + dataBytes)
        
        return magic + version + typeByte + length + dataBytes + crc32
    }
    
    func removeOldWppmMarkers(from fileURL: URL) throws {
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 ?? 0
        if fileSize < Int64(minimumMarkerSize) {
            return
        }
        
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }
        
        let startOffset = max(0, fileSize - Int64(searchBufferSize))
        try fileHandle.seek(toOffset: UInt64(startOffset))
        
        guard let buffer = try fileHandle.readToEnd() else {
            return
        }
        
        var lastMarkerStart: Int?
        let signatureLength = magic.count
        
        for i in (0...buffer.count - signatureLength).reversed() {
            let slice = buffer.subdata(in: i..<i+signatureLength)
            if slice == magic {
                lastMarkerStart = i
                break
            }
        }
        
        guard let markerStart = lastMarkerStart else {
            return
        }
        
        let actualFileEndPosition = startOffset + Int64(markerStart)
        
        let writeHandle = try FileHandle(forWritingTo: fileURL)
        try writeHandle.truncate(atOffset: UInt64(actualFileEndPosition))
        writeHandle.closeFile()
        
        zipLogger.debug("✅ 已清理旧的 WPPM 标记，截断位置: \(actualFileEndPosition)")
    }
    
    private func intToByteArrayLittleEndian(_ value: Int) -> Data {
        var result = Data(count: 4)
        result[0] = UInt8(value & 0xFF)
        result[1] = UInt8((value >> 8) & 0xFF)
        result[2] = UInt8((value >> 16) & 0xFF)
        result[3] = UInt8((value >> 24) & 0xFF)
        return result
    }
    
    private func byteArrayToIntLittleEndian(_ data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        return (Int(data[3]) << 24) | (Int(data[2]) << 16) | (Int(data[1]) << 8) | Int(data[0])
    }
    
    private func calculateCRC32(_ data: Data) -> Data {
        var crc: UInt32 = 0xFFFFFFFF
        
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0)
            }
        }
        
        crc = ~crc
        return intToByteArrayLittleEndian(Int(crc))
    }
}

extension Data {
    var hexDescription: String {
        return map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    var hexDescriptionShort: String {
        let maxLength = 32
        let description = map { String(format: "%02X", $0) }.joined(separator: " ")
        if description.count > maxLength * 3 {
            return String(description.prefix(maxLength * 3)) + "..."
        }
        return description
    }
}