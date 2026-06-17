# 文件元数据读写规范文档

---

## 一、概述

本文档详细描述WPS文档密码管理器中**文件元数据的读取和写入方法**，旨在为iOS版本提供清晰的实现参考。文档重点关注元数据的数据结构、存储格式和操作流程，暂不涉及密码解密相关内容。

---

## 二、元数据数据结构

### 2.1 FileMeta 模型

文件元数据包含以下核心字段：

| 字段名 | 类型 | 说明 | 是否必填 |
|-------|------|------|---------|
| `filePath` | String | 文件绝对路径（唯一标识） | 是 |
| `uid` | String? | 文件权限标识 | 否 |
| `currentPassword` | String? | 当前生效密码（加密后存储） | 否 |
| `pendingPasswordList` | List<String>? | 待定密码列表 | 否 |
| `currentKeyVersion` | String | 密钥版本，默认"default" | 是 |
| `ownerAccount` | String? | 文档所属账号 | 否 |
| `ownerName` | String? | 文档所属名称 | 否 |
| `readAuth` | Bool | 读权限 | 否 |
| `writeAuth` | Bool | 写权限 | 否 |
| `isTempUid` | Bool | 是否临时UID | 否 |

**Swift实现示例**：
```swift
struct FileMeta: Codable {
    let filePath: String
    var uid: String?
    var currentPassword: String?
    var pendingPasswordList: [String]?
    var currentKeyVersion: String = "default"
    var ownerAccount: String?
    var ownerName: String?
    var readAuth: Bool = false
    var writeAuth: Bool = false
    var isTempUid: Bool = false
}
```

---

## 三、元数据存储格式规范

### 3.1 WPPM标记格式

元数据以 **WPPM标记** 的形式存储在文档文件尾部，每个标记遵循以下二进制格式：

```
┌─────────────────────────────────────────────────────────────┐
│                     WPPM标记结构                            │
├────────────┬────────────┬─────────┬──────────┬──────┬───────┤
│ Magic(4B)  │ Version(2B)│ Type(1B)│ Length(4B)│ Data │ CRC32 │
│            │ 小端序     │         │ 小端序    │(N B) │(4B)  │
└────────────┴────────────┴─────────┴──────────┴──────┴───────┘
```

**字段说明**：

| 字段 | 大小 | 说明 |
|------|------|------|
| **Magic** | 4字节 | 固定为 "WPPM"（ASCII字符串） |
| **Version** | 2字节 | 版本号，当前为1（小端序） |
| **Type** | 1字节 | 元数据类型标识 |
| **Length** | 4字节 | Data字段长度（小端序） |
| **Data** | N字节 | 实际数据内容（UTF-8编码明文） |
| **CRC32** | 4字节 | 校验和（计算范围：Magic到Data） |

### 3.2 元数据类型定义

| Type值 | 类型名称 | 说明 |
|--------|---------|------|
| `0x01` | METADATA_TYPE_PASSWORD | 密码数据 |
| `0x02` | METADATA_TYPE_UID | 文档权限标识 |
| `0x03` | METADATA_TYPE_KEY_VERSION | 密钥版本 |

### 3.3 多标记存储规则

一个文件尾部可存储多个WPPM标记，按顺序依次写入：

```
文件内容...[UID标记][PASSWORD标记][KEY_VERSION标记]
```

读取时从文件尾部向前搜索，找到最新的对应类型标记。

---

## 四、元数据写入方法

### 4.1 写入流程

```
┌─────────────────────────────────────────────────────────────┐
│                      写入流程                               │
├─────────────────────────────────────────────────────────────┤
│ 1. 检查文件存在性和可写权限                                   │
│            ↓                                                │
│ 2. 检测文件是否被锁定（重试机制）                              │
│            ↓                                                │
│ 3. 删除旧的WPPM标记（避免重复）                                │
│            ↓                                                │
│ 4. 构建各类型的Extra Field数据                                │
│            ↓                                                │
│ 5. 依次写入UID、PASSWORD、KEY_VERSION标记                      │
│            ↓                                                │
│ 6. 验证写入结果                                               │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 核心写入逻辑

**步骤1：检查文件状态**
```swift
func writeMetaDataToFile(file: URL, fileMeta: FileMeta) -> Bool {
    let filePath = file.path
    guard FileManager.default.fileExists(atPath: filePath) else {
        return false
    }
    
    let fileHandle = try? FileHandle(forWritingTo: file)
    guard fileHandle != nil else {
        return false
    }
    // ... 继续写入逻辑
}
```

**步骤2：构建Extra Field数据**

每个标记的数据结构构建方法：

```swift
private func buildExtraFieldData(type: Int, data: String) -> Data {
    let magic = "WPPM".data(using: .ascii)!
    let version = Data([0x01, 0x00])  // 版本1，小端序
    let typeByte = Data([UInt8(type)])
    let dataBytes = data.data(using: .utf8)!
    let length = intToByteArrayLittleEndian(dataBytes.count)
    let crc32 = calculateCRC32(magic + version + typeByte + length + dataBytes)
    
    return magic + version + typeByte + length + dataBytes + crc32
}
```

**步骤3：字节序转换工具**

小端序转换方法：

```swift
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
```

**步骤4：CRC32校验和计算**

```swift
private func calculateCRC32(_ data: Data) -> Data {
    var crc32 = CRC32()
    crc32.update(data: data)
    let value = crc32.finalize()
    return intToByteArrayLittleEndian(Int(value))
}
```

**步骤5：写入文件尾部**

```swift
private func appendToFile(_ file: URL, data: Data) -> Bool {
    do {
        let fileHandle = try FileHandle(forWritingTo: file)
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        fileHandle.closeFile()
        return true
    } catch {
        return false
    }
}
```

### 4.3 旧标记删除机制

在写入新标记前，需要删除旧的WPPM标记：

```swift
private func removeOldWppmMarkers(_ file: URL) -> Bool {
    // 1. 读取文件尾部1KB数据
    // 2. 查找所有WPPM标记位置
    // 3. 创建临时文件，复制除标记外的内容
    // 4. 用临时文件替换原文件
}
```

**标记查找算法**：从文件尾部1KB范围内，从后向前搜索"WPPM"签名。

---

## 五、元数据读取方法

### 5.1 读取流程

```
┌─────────────────────────────────────────────────────────────┐
│                      读取流程                               │
├─────────────────────────────────────────────────────────────┤
│ 1. 检查文件存在性和可读权限                                   │
│            ↓                                                │
│ 2. 读取文件尾部1KB数据                                       │
│            ↓                                                │
│ 3. 从后向前搜索WPPM签名                                      │
│            ↓                                                │
│ 4. 根据Type筛选目标类型标记                                   │
│            ↓                                                │
│ 5. 解析标记数据并验证CRC32                                    │
│            ↓                                                │
│ 6. 返回解析结果                                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 核心读取逻辑

**步骤1：读取文件尾部数据**

```swift
func readPassword(from file: URL) -> String? {
    return readMetadata(from: file, type: 1)
}

func readUid(from file: URL) -> String? {
    return readMetadata(from: file, type: 2)
}

func readKeyVersion(from file: URL) -> String? {
    return readMetadata(from: file, type: 3)
}
```

**步骤2：通用读取方法**

```swift
private func readMetadata(from file: URL, type: Int) -> String? {
    guard let data = try? Data(contentsOf: file) else {
        return nil
    }
    
    let fileLength = data.count
    if fileLength < 20 {  // 最小标记大小
        return nil
    }
    
    // 读取尾部1KB
    let bufferSize = 1024
    let startPosition = max(0, fileLength - bufferSize)
    let buffer = data.subdata(in: startPosition..<fileLength)
    
    // 从后向前搜索WPPM签名
    let signature = "WPPM".data(using: .ascii)!
    let signatureLength = signature.count
    
    for i in (0...buffer.count - signatureLength).reversed() {
        let slice = buffer.subdata(in: i..<i+signatureLength)
        if slice == signature {
            // 找到签名，解析完整标记
            let absolutePosition = startPosition + i
            return parseMetadata(at: absolutePosition, in: data, expectedType: type)
        }
    }
    
    return nil
}
```

**步骤3：解析标记数据**

```swift
private func parseMetadata(at position: Int, in data: Data, expectedType: Int) -> String? {
    let remainingLength = data.count - position
    if remainingLength < 15 {  // Magic(4) + Version(2) + Type(1) + Length(4) + CRC32(4)
        return nil
    }
    
    let magic = data.subdata(in: position..<position+4)
    guard String(data: magic, encoding: .ascii) == "WPPM" else {
        return nil
    }
    
    let type = Int(data[position+6])
    guard type == expectedType else {
        return nil
    }
    
    let lengthBytes = data.subdata(in: position+7..<position+11)
    let dataLength = byteArrayToIntLittleEndian(lengthBytes)
    
    // 验证数据长度
    if position + 11 + dataLength + 4 > data.count {
        return nil
    }
    
    // 读取数据内容
    let contentData = data.subdata(in: position+11..<position+11+dataLength)
    
    // 验证CRC32
    let expectedCrc32 = data.subdata(in: position+11+dataLength..<position+11+dataLength+4)
    let calculatedCrc32 = calculateCRC32(
        magic + 
        data.subdata(in: position+4..<position+6) +  // Version
        Data([UInt8(type)]) + 
        lengthBytes + 
        contentData
    )
    
    guard expectedCrc32 == calculatedCrc32 else {
        return nil  // CRC校验失败
    }
    
    return String(data: contentData, encoding: .utf8)
}
```

### 5.3 输入流读取模式

支持从输入流直接读取（适用于Content URI或网络流）：

```swift
func readMetadataFromInputStream(_ inputStream: InputStream, type: Int) -> String? {
    // 将输入流转换为Data
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    
    while inputStream.hasBytesAvailable {
        let bytesRead = inputStream.read(buffer, maxLength: 1024)
        if bytesRead > 0 {
            data.append(buffer, count: bytesRead)
        }
    }
    
    buffer.deallocate()
    
    // 后续逻辑同文件读取...
}
```

---

## 六、iOS实现关键要点

### 6.1 文件操作注意事项

| 要点 | 说明 |
|------|------|
| **沙盒限制** | iOS应用只能访问自身沙盒目录和用户通过文件选择器授权的文件 |
| **文件权限** | 使用 `UIDocumentPickerViewController` 获取文件访问权限 |
| **iCloud同步** | 考虑iCloud文档目录的读写同步问题 |
| **文件锁定检测** | 写入前检查文件是否被其他进程占用 |

### 6.2 重试机制

写入操作需要实现重试机制处理文件锁定：

```swift
private let maxRetryCount = 5
private let retryDelayMs = 1000

func writeWithRetry(file: URL, data: Data) -> Bool {
    for attempt in 0..<maxRetryCount {
        if isFileLocked(file) {
            Thread.sleep(forTimeInterval: TimeInterval(retryDelayMs) / 1000)
            continue
        }
        
        if appendToFile(file, data: data) {
            return true
        }
        
        Thread.sleep(forTimeInterval: TimeInterval(retryDelayMs) / 1000)
    }
    
    return false
}

private func isFileLocked(_ file: URL) -> Bool {
    do {
        let fileHandle = try FileHandle(forWritingTo: file)
        fileHandle.closeFile()
        return false
    } catch {
        return true
    }
}
```

### 6.3 数据格式兼容性

| 兼容性要点 | 说明 |
|-----------|------|
| **字节序** | 所有多字节字段使用小端序（Little Endian） |
| **编码格式** | Data字段使用UTF-8编码 |
| **校验算法** | 使用标准CRC32算法 |
| **标记顺序** | 按UID → PASSWORD → KEY_VERSION顺序写入 |

---

## 七、错误处理与日志

### 7.1 错误类型

| 错误场景 | 处理策略 |
|---------|---------|
| 文件不存在 | 返回nil并记录错误日志 |
| 文件不可读写 | 返回nil并记录权限错误 |
| CRC校验失败 | 返回nil并记录数据损坏警告 |
| 数据格式错误 | 返回nil并记录解析错误 |
| 文件被锁定 | 重试或返回失败 |

### 7.2 日志记录建议

```swift
func log(_ message: String, level: LogLevel = .info) {
    // 记录元数据操作日志，便于排查问题
    // 注意：日志中不记录敏感数据（如密码）
}
```

---

## 八、总结

| 维度 | 实现要点 |
|------|---------|
| **存储位置** | 文件尾部的WPPM标记区域 |
| **数据格式** | Magic(4) + Version(2) + Type(1) + Length(4) + Data(N) + CRC32(4) |
| **字节序** | 小端序（Little Endian） |
| **编码** | UTF-8 |
| **校验** | CRC32覆盖Magic到Data部分 |
| **读取策略** | 从文件尾部1KB向前搜索 |
| **写入策略** | 先删除旧标记，再写入新标记 |

---

**文档版本**: v1.0  
**创建日期**: 2026-06-15  
**适用项目**: WPS密码管理器iOS版本  
**参考文件**: 
- `FileMeta.kt`
- `FileMetaManager.kt`  
- `ZipExtraFieldManager.kt`