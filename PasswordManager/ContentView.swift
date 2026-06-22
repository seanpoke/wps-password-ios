import SwiftUI
import OSLog
import UIKit

struct ContentView: View {
    @State private var records: [FileMappingRecord] = []
    @State private var selectedRecord: FileMappingRecord?
    @State private var isRefreshing = false
    @State private var deleteConfirmRecord: FileMappingRecord?
    @State private var showDeleteAlert = false
    @State private var toastMessage: String?
    @State private var toastVisible = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(records, id: \.uid) { record in
                    AssetRow(record: record, onTap: {
                        openFile(record: record)
                    }, onLockTap: {
                        selectedRecord = record
                    })
                }
                .onDelete(perform: requestDelete)
                
                if records.isEmpty {
                    Text("暂无资产记录")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .navigationTitle("资产保险箱")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: refreshList) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable {
                await loadRecords()
            }
            .onAppear {
                loadRecords()
            }
            .sheet(item: $selectedRecord) { record in
                AssetDetailView(record: record)
            }
            .alert("确认删除", isPresented: $showDeleteAlert, actions: {
                Button("取消", role: .cancel) {
                    deleteConfirmRecord = nil
                }
                Button("删除", role: .destructive) {
                    if let record = deleteConfirmRecord {
                        deleteRecord(record: record)
                    }
                    deleteConfirmRecord = nil
                }
            }, message: {
                if let record = deleteConfirmRecord {
                    Text("确定要删除 \"\(record.file_name)\" 吗？此操作不可撤销。")
                }
            })
            .overlay(
                Group {
                    if isRefreshing {
                        ProgressView("加载中...")
                    }
                }
            )
            .overlay(
                Group {
                    if toastVisible, let message = toastMessage {
                        ToastView(message: message)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            )
        }
    }
    
    private func loadRecords() {
        isRefreshing = true
        DispatchQueue.global().async {
            let allRecords = AppGroupDBManager.shared.queryAllLocalVaultRecords()
            DispatchQueue.main.async {
                records = allRecords.sorted { $0.last_access_time > $1.last_access_time }
                isRefreshing = false
            }
        }
    }
    
    private func refreshList() {
        loadRecords()
    }
    
    private func requestDelete(at offsets: IndexSet) {
        for offset in offsets {
            let record = records[offset]
            deleteConfirmRecord = record
            showDeleteAlert = true
            return
        }
    }
    
    private func deleteRecord(record: FileMappingRecord) {
        let appGroupID = "group.com.greenet.PasswordManager"
        let safeVaultDir = "SafeVault"
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return
        }
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        let fileURL = vaultDir.appendingPathComponent(record.file_name)
        
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            AppGroupDBManager.shared.deleteRecord(uid: record.uid)
            records.removeAll { $0.uid == record.uid }
        } catch {
            appLogger.error("❌ 删除文件失败: \(error)")
        }
    }
    
    private func openFile(record: FileMappingRecord) {
        let appGroupID = "group.com.greenet.PasswordManager"
        let safeVaultDir = "SafeVault"
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return
        }
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        let fileURL = vaultDir.appendingPathComponent(record.file_name)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            appLogger.error("❌ 文件不存在: \(fileURL.path)")
            return
        }
        
        DispatchQueue.global().async {
            let password = ZipExtraFieldManager.shared.readPassword(from: fileURL)
            
            DispatchQueue.main.async {
                if let password = password {
                    UIPasteboard.general.string = password
                    appLogger.info("🔑 密码已复制到剪贴板")
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        if UIPasteboard.general.string == password {
                            UIPasteboard.general.string = nil
                            appLogger.info("🔐 剪贴板已清理")
                        }
                    }
                    
                    self.showToast(message: "密码已复制到剪贴板")
                }
                
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
                      var topVC = window.rootViewController else {
                    return
                }
                
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                
                _ = topVC.view
                
                let tempDir = FileManager.default.temporaryDirectory
                let tempFileURL = tempDir.appendingPathComponent(record.file_name)
                
                do {
                    if FileManager.default.fileExists(atPath: tempFileURL.path) {
                        try FileManager.default.removeItem(at: tempFileURL)
                    }
                    try FileManager.default.copyItem(at: fileURL, to: tempFileURL)
                    appLogger.info("📤 文件已复制到临时目录: \(tempFileURL.path)")
                    
                    appLogger.info("🚀 直接打开文件")
                    UIApplication.shared.open(tempFileURL) { success in
                        if success {
                            appLogger.info("✅ 文件打开成功")
                            
                            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                                do {
                                    if FileManager.default.fileExists(atPath: tempFileURL.path) {
                                        try FileManager.default.removeItem(at: tempFileURL)
                                        appLogger.info("🗑️ 临时文件已清理")
                                    }
                                } catch {
                                    appLogger.error("❌ 清理临时文件失败: \(error)")
                                }
                            }
                            
                            DispatchQueue.global().async {
                                AppGroupDBManager.shared.updateAccessTime(uid: record.uid)
                                appLogger.info("📅 已更新文件访问时间: \(record.file_name)")
                            }
                        } else {
                            appLogger.error("❌ 文件打开失败")
                            
                            do {
                                if FileManager.default.fileExists(atPath: tempFileURL.path) {
                                    try FileManager.default.removeItem(at: tempFileURL)
                                    appLogger.info("🗑️ 打开失败，清理临时文件")
                                }
                            } catch {
                                appLogger.error("❌ 清理临时文件失败: \(error)")
                            }
                        }
                    }
                } catch {
                    appLogger.error("❌ 复制文件失败: \(error)")
                }
            }
        }
    }
    
    private func showToast(message: String) {
        toastMessage = message
        toastVisible = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            toastVisible = false
        }
    }
}

struct ToastView: View {
    let message: String
    
    var body: some View {
        VStack {
            Text(message)
                .foregroundColor(.white)
                .font(.body)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 100)
    }
}

struct AssetRow: View {
    let record: FileMappingRecord
    let onTap: () -> Void
    let onLockTap: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Left content is tappable
            HStack(spacing: 16) {
                FileIconView(fileName: record.file_name)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.file_name)
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        Text(formatFileSize(record.file_size))
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Text(formatDate(record.last_access_time))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            
            Spacer()
            
            // Lock button is NOT part of the tappable area
            Button(action: onLockTap) {
                Image(systemName: record.is_local_vault == 1 ? "lock.fill" : "lock.open")
                    .foregroundColor(record.is_local_vault == 1 ? .green : .orange)
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
    
    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct FileIconView: View {
    let fileName: String
    
    private var iconInfo: (name: String, color: Color) {
        if fileName.hasSuffix(".docx") || fileName.hasSuffix(".doc") {
            return ("doc.text", .blue)
        } else if fileName.hasSuffix(".xlsx") || fileName.hasSuffix(".xls") {
            return ("table", .green)
        } else if fileName.hasSuffix(".pptx") || fileName.hasSuffix(".ppt") {
            return ("doc.text.fill", .orange)
        } else if fileName.hasSuffix(".pdf") {
            return ("doc", .red)
        } else {
            return ("file", .gray)
        }
    }
    
    var body: some View {
        Image(systemName: iconInfo.name)
            .font(.system(size: 32))
            .foregroundColor(iconInfo.color)
            .frame(width: 48, height: 48)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
    }
}

struct AssetDetailView: View {
    let record: FileMappingRecord
    @State private var password: String?
    @State private var isCopied = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    FileIconView(fileName: record.file_name)
                        .scaleEffect(2)
                    
                    VStack(spacing: 8) {
                        Text(record.file_name)
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        
                        HStack(spacing: 16) {
                            InfoRow(label: "文件大小", value: formatFileSize(record.file_size))
                            InfoRow(label: "最后访问", value: formatDate(record.last_access_time))
                        }
                        
                        InfoRow(label: "存储位置", value: record.is_local_vault == 1 ? "本地保险箱" : "外部")
                            .foregroundColor(record.is_local_vault == 1 ? .green : .orange)
                    }
                    
                    Divider()
                    
                    VStack(spacing: 16) {
                        Text("解密密码")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if let password = password {
                            VStack(spacing: 8) {
                                Text(password)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .multilineTextAlignment(.center)
                                    .padding()
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(8)
                                    .lineLimit(nil)
                                
                                Button(action: copyPassword) {
                                    HStack(spacing: 8) {
                                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                        Text(isCopied ? "已复制" : "复制密码")
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(isCopied ? Color.green : Color.blue)
                                    .cornerRadius(12)
                                }
                            }
                        } else {
                            ProgressView("读取密码中...")
                        }
                    }
                    
                    VStack(spacing: 16) {
                        Text("文件标识")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Text(record.uid)
                            .font(.caption)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .lineLimit(nil)
                    }
                }
                .padding()
            }
            .navigationTitle("资产详情")
            .onAppear {
                readPassword()
            }
        }
    }
    
    private func readPassword() {
        let appGroupID = "group.com.greenet.PasswordManager"
        let safeVaultDir = "SafeVault"
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return
        }
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        let fileURL = vaultDir.appendingPathComponent(record.file_name)
        
        DispatchQueue.global().async {
            let passwordFromFile = ZipExtraFieldManager.shared.readPassword(from: fileURL)
            DispatchQueue.main.async {
                self.password = passwordFromFile ?? "未找到密码"
            }
        }
    }
    
    private func copyPassword() {
        guard let password = password else { return }
        UIPasteboard.general.string = password
        isCopied = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
    
    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

import CommonCrypto