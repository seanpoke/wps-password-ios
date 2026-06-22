import SwiftUI
import OSLog
import UIKit

class DocumentPreviewDelegate: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = DocumentPreviewDelegate()
    
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
              let rootVC = window.rootViewController else {
            return UIViewController()
        }
        
        // Find the topmost view controller
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        return topVC
    }
}

struct ContentView: View {
    @State private var records: [FileMappingRecord] = []
    @State private var selectedRecord: FileMappingRecord?
    @State private var isRefreshing = false
    
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
                .onDelete(perform: deleteRecords)
                
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
            .overlay(
                Group {
                    if isRefreshing {
                        ProgressView("加载中...")
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
    
    private func deleteRecords(at offsets: IndexSet) {
        for offset in offsets {
            let record = records[offset]
            deleteRecord(record: record)
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
        
        // Defer to next runloop tick to ensure view hierarchy is ready
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
                  var topVC = window.rootViewController else {
                return
            }
            
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            
            // Ensure the view is loaded
            _ = topVC.view
            
            let documentController = UIDocumentInteractionController(url: fileURL)
            documentController.delegate = DocumentPreviewDelegate.shared
            documentController.presentPreview(animated: true)
        }
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