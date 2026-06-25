import SwiftUI
import OSLog
import UIKit
import Combine

class DocumentInteractionManager: ObservableObject {
    @Published private(set) var isPreviewing = false
    private var docController: UIDocumentInteractionController?
    private var delegate: DocumentInteractionDelegate?
    
    func openFile(url: URL, uid: String, fileName: String, presentingViewController: UIViewController) {
        appLogger.info("🔍 优先尝试唤起外部应用打开文件")
        UIApplication.shared.open(url) { [weak self] success in
            if success {
                appLogger.info("✅ 外部应用打开成功")
                
                DispatchQueue.global().async {
                    AppGroupDBManager.shared.updateAccessTime(uid: uid)
                    appLogger.info("📅 已更新文件访问时间: \(fileName)")
                }
                
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    self?.cleanupTempFile(url: url)
                }
            } else {
                appLogger.info("❌ 外部应用打开失败，降级到系统预览")
                self?.presentSystemPreview(url: url, uid: uid, fileName: fileName, presentingViewController: presentingViewController)
            }
        }
    }
    
    func presentSystemPreview(url: URL, uid: String, fileName: String, presentingViewController: UIViewController) {
        docController = UIDocumentInteractionController(url: url)
        delegate = DocumentInteractionDelegate(
            tempFileURL: url,
            uid: uid,
            fileName: fileName,
            presentingViewController: presentingViewController,
            manager: self
        )
        docController?.delegate = delegate
        isPreviewing = true
        docController?.presentPreview(animated: true)
    }
    
    func previewDidEnd() {
        isPreviewing = false
        docController = nil
        delegate = nil
    }
    
    private func cleanupTempFile(url: URL) {
        DispatchQueue.global().async {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    appLogger.info("🗑️ 临时文件已清理")
                }
            } catch {
                appLogger.error("❌ 清理临时文件失败: \(error)")
            }
        }
    }
}

struct ContentView: View {
    var onLogout: () -> Void
    
    @State private var records: [FileMappingRecord] = []
    @State private var filteredRecords: [FileMappingRecord] = []
    @State private var searchText = ""
    @State private var selectedRecord: FileMappingRecord?
    @State private var isRefreshing = false
    @State private var deleteConfirmRecord: FileMappingRecord?
    @State private var showDeleteAlert = false
    @State private var toastMessage: String?
    @State private var toastVisible = false
    @State private var showDebugView = false
    @State private var searchBarTapCount = 0
    @State private var lastTapTime = Date()
    @State private var showLogoutSheet = false
    @State private var userName = ""
    
    @State private var searchIndex = SearchIndex()
    @StateObject private var docInteractionManager = DocumentInteractionManager()
    @ObservedObject private var diskSpaceManager = DiskSpaceManager.shared
    @State private var showDiskSpaceWarning = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(userName)，你好")
                            .font(.title)
                            .fontWeight(.bold)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        showLogoutSheet = true
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.6, green: 0.8, blue: 1.0))
                                .frame(width: 44, height: 44)
                            
                            Text(userName.first?.description ?? "")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                SearchBar(text: $searchText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.systemBackground))
                
                Divider()
                    .padding(.horizontal, 16)
                
                List {
                    ForEach(filteredRecords, id: \.id) { record in
                        AssetRow(record: record, onTap: {
                            openFile(record: record)
                        }, onLockTap: {
                            selectedRecord = record
                        }, onPreviewTap: {
                            openFilePreview(record: record)
                        })
                    }
                    .onDelete(perform: requestDelete)
                    
                    if filteredRecords.isEmpty {
                        Text(searchText.isEmpty ? "暂无资产记录" : "未找到匹配的资产")
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .listStyle(.plain)
                .onTapGesture {
                    let now = Date()
                    let timeDiff = now.timeIntervalSince(lastTapTime)                    
                    if timeDiff < 0.5 {
                        searchBarTapCount += 1
                    } else {
                        searchBarTapCount = 1
                    }
                    lastTapTime = now
                                        
                    if searchBarTapCount >= 3 {
                        searchBarTapCount = 0
                        showDebugView = true
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: refreshList) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showDebugView) {
                DebugDatabaseView()
            }
            .refreshable {
                await loadRecords()
            }
            .onAppear {
                loadRecords()
                loadUserName()
            }
            .onChange(of: searchText) {
                filterRecords()
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
            .onChange(of: diskSpaceManager.shouldShowWarning) { newValue in
                if newValue {
                    showDiskSpaceAlert()
                }
            }
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
            .sheet(isPresented: $showLogoutSheet) {
                VStack(spacing: 12) {
                    Text("是否确认注销？")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("注销后将返回登录页面，需要重新登录")
                        .font(.body)
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 16) {
                        Button(action: {
                            showLogoutSheet = false
                        }) {
                            Text("取消")
                                .font(.headline)
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.systemGray5))
                                .cornerRadius(12)
                        }
                        
                        Button(action: {
                            showLogoutSheet = false
                            onLogout()
                        }) {
                            Text("注销")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding()
                .presentationDetents([.height(200)])
            }
        }
    }
    
    private func loadRecords() {
        isRefreshing = true
        DispatchQueue.global().async {
            let allRecords = AppGroupDBManager.shared.queryAllLocalVaultRecords()
            let sortedRecords = allRecords.sorted { $0.last_access_time > $1.last_access_time }
            searchIndex.buildIndex(records: sortedRecords)
            DispatchQueue.main.async {
                records = sortedRecords
                filterRecords()
                isRefreshing = false
            }
        }
    }
    
    private func loadUserName() {
        DispatchQueue.global().async {
            let name = AppGroupDBManager.shared.getConfigValue(key: GlobalConfigKey.name) ?? ""
            DispatchQueue.main.async {
                self.userName = name
            }
        }
    }
    
    private func filterRecords() {
        if searchText.isEmpty {
            filteredRecords = records
        } else {
            filteredRecords = searchIndex.search(query: searchText)
        }
    }
    
    private func refreshList() {
        loadRecords()
        Task {
            await diskSpaceManager.checkDiskSpace()
        }
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
        let dbFileName = record.file_name
        var fileURL = vaultDir.appendingPathComponent(dbFileName)
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: vaultDir, includingPropertiesForKeys: nil)
                for candidateURL in files {
                    if candidateURL.lastPathComponent.lowercased() == dbFileName.lowercased() {
                        fileURL = candidateURL
                        break
                    }
                }
            } catch {
                appLogger.error("❌ 遍历保险箱目录失败: \(error)")
            }
        }
        
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            AppGroupDBManager.shared.deleteRecord(ids: [record.id])
            loadRecords()
        } catch {
            appLogger.error("❌ 删除文件失败: \(error)")
        }
    }
    
    private func openFile(record: FileMappingRecord) {
        copyFileAndOpen(record: record, usePreview: false)
    }
    
    private func openFilePreview(record: FileMappingRecord) {
        copyFileAndOpen(record: record, usePreview: true)
    }
    
    private func copyFileAndOpen(record: FileMappingRecord, usePreview: Bool) {
        let appGroupID = "group.com.greenet.PasswordManager"
        let safeVaultDir = "SafeVault"
        
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return
        }
        
        let vaultDir = containerURL.appendingPathComponent(safeVaultDir, isDirectory: true)
        let dbFileName = record.file_name
        var fileURL = vaultDir.appendingPathComponent(dbFileName)
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            appLogger.warning("⚠️ 文件名 \(dbFileName) 不存在，尝试大小写不敏感匹配")
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: vaultDir, includingPropertiesForKeys: nil)
                for candidateURL in files {
                    if candidateURL.lastPathComponent.lowercased() == dbFileName.lowercased() {
                        fileURL = candidateURL
                        appLogger.info("✅ 找到匹配文件: \(fileURL.lastPathComponent)")
                        break
                    }
                }
            } catch {
                appLogger.error("❌ 遍历保险箱目录失败: \(error)")
            }
        }
        
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
                    
                    if usePreview {
                        appLogger.info("🚀 使用文档交互管理器直接预览文件")
                        DispatchQueue.global().async {
                            AppGroupDBManager.shared.updateAccessTime(uid: record.uid)
                            appLogger.info("📅 已更新文件访问时间: \(record.file_name)")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.docInteractionManager.presentSystemPreview(
                                url: tempFileURL,
                                uid: record.uid,
                                fileName: record.file_name,
                                presentingViewController: topVC
                            )
                        }
                    } else {
                        appLogger.info("🚀 使用文档交互管理器打开文件")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.docInteractionManager.openFile(
                                url: tempFileURL,
                                uid: record.uid,
                                fileName: record.file_name,
                                presentingViewController: topVC
                            )
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
    
    private func showDiskSpaceAlert() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
              var topVC = window.rootViewController else {
            return
        }
        
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        let alert = UIAlertController(
            title: "磁盘空间警告",
            message: "当前保险箱占用空间已超过1GB，建议您手动删除不再需要的文件以释放磁盘空间。",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "不再提示", style: .default) { _ in
            self.diskSpaceManager.dismissWarning(permanently: true)
        })
        
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            self.diskSpaceManager.dismissWarning()
        })
        
        topVC.present(alert, animated: true)
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
    let onPreviewTap: () -> Void
    
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
            
            Button(action: onPreviewTap) {
                Image(systemName: "eye.fill")
                    .foregroundColor(.gray)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            
            Button(action: onLockTap) {
                Image(systemName: "info.circle")
                    .foregroundColor(.gray)
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
    
    private var iconInfo: (letter: String, bgColor: Color, fgColor: Color) {
        if fileName.hasSuffix(".docx") || fileName.hasSuffix(".doc") {
            return ("W", Color(red: 0.12, green: 0.33, blue: 0.73), .white)
        } else if fileName.hasSuffix(".xlsx") || fileName.hasSuffix(".xls") {
            return ("S", Color(red: 0.15, green: 0.58, blue: 0.24), .white)
        } else if fileName.hasSuffix(".pptx") || fileName.hasSuffix(".ppt") {
            return ("P", Color(red: 0.92, green: 0.45, blue: 0.13), .white)
        } else if fileName.hasSuffix(".pdf") {
            return ("P", Color(red: 0.79, green: 0.21, blue: 0.21), .white)
        } else {
            return ("", Color(.secondarySystemBackground), .gray)
        }
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(iconInfo.bgColor)
                .frame(width: 44, height: 44)
            
            if !iconInfo.letter.isEmpty {
                Text(iconInfo.letter)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(iconInfo.fgColor)
            } else {
                Image(systemName: "file")
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
            }
        }
    }
}

struct AssetDetailView: View {
    let record: FileMappingRecord
    
    private var fileType: String {
        let lowerName = record.file_name.lowercased()
        if lowerName.hasSuffix(".docx") {
            return "DOCX"
        } else if lowerName.hasSuffix(".doc") {
            return "DOC"
        } else if lowerName.hasSuffix(".xlsx") {
            return "XLSX"
        } else if lowerName.hasSuffix(".xls") {
            return "XLS"
        } else if lowerName.hasSuffix(".pptx") {
            return "PPTX"
        } else if lowerName.hasSuffix(".ppt") {
            return "PPT"
        } else if lowerName.hasSuffix(".pdf") {
            return "PDF"
        } else if lowerName.hasSuffix(".zip") {
            return "ZIP"
        } else {
            if let ext = record.file_name.components(separatedBy: ".").last {
                return ext.uppercased()
            }
            return "未知"
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        Text("文件基本信息")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        InfoRow(label: "文件名称", value: record.file_name)
                        InfoRow(label: "文件类型", value: fileType)
                        InfoRow(label: "文件大小", value: formatFileSize(record.file_size))
                        InfoRow(label: "创建时间", value: formatDate(record.create_time))
                        InfoRow(label: "修改时间", value: formatDate(record.update_time))
                        InfoRow(label: "访问时间", value: formatDate(record.last_access_time))
                    }
                    
                    Divider()
                    
                    VStack(spacing: 16) {
                        Text("文件元数据信息")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        InfoRow(label: "uid", value: record.uid)
                        InfoRow(label: "密码", value: record.password_hash)
                        InfoRow(label: "密钥版本", value: "1.0")
                    }
                    
                    Divider()
                    
                    VStack(spacing: 16) {
                        Text("文档权限信息")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Text("暂无权限信息")
                            .font(.body)
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("文件信息")
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
                .textSelection(.enabled)
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            
            TextField("请输入文件名", text: $text)
                .textFieldStyle(.plain)
            
            if !text.isEmpty {
                Button(action: {
                    text = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

class SearchIndex {
    private var index: [String: [FileMappingRecord]] = [:]
    private var allRecords: [FileMappingRecord] = []
    
    func buildIndex(records: [FileMappingRecord]) {
        allRecords = records
        index.removeAll()
        
        for record in records {
            let tokens = tokenize(text: record.file_name)
            for token in tokens {
                if index[token] == nil {
                    index[token] = []
                }
                if !index[token]!.contains(where: { $0.id == record.id }) {
                    index[token]!.append(record)
                }
            }
        }
    }
    
    func search(query: String) -> [FileMappingRecord] {
        let queryTokens = tokenize(text: query)
        
        if queryTokens.isEmpty {
            return allRecords
        }
        
        var results: [FileMappingRecord] = []
        
        if let firstToken = queryTokens.first, let firstRecords = index[firstToken] {
            results = firstRecords
            
            for token in queryTokens.dropFirst() {
                if let matchedRecords = index[token] {
                    results = results.filter { record in
                        matchedRecords.contains { $0.id == record.id }
                    }
                } else {
                    results = []
                    break
                }
            }
        }
        
        results.sort { record1, record2 in
            let score1 = calculateScore(record: record1, query: query)
            let score2 = calculateScore(record: record2, query: query)
            return score1 > score2
        }
        
        return results
    }
    
    private func tokenize(text: String) -> [String] {
        var tokens: [String] = []
        let lowerText = text.lowercased()
        
        for i in 0..<lowerText.count {
            let start = lowerText.index(lowerText.startIndex, offsetBy: i)
            for j in i..<min(i + 2, lowerText.count) {
                let end = lowerText.index(lowerText.startIndex, offsetBy: j + 1)
                let substring = String(lowerText[start..<end])
                if !substring.isEmpty {
                    tokens.append(substring)
                }
            }
        }
        
        return Array(Set(tokens))
    }
    
    private func calculateScore(record: FileMappingRecord, query: String) -> Int {
        let fileName = record.file_name.lowercased()
        let queryLower = query.lowercased()
        var score = 0
        
        if fileName.hasPrefix(queryLower) {
            score += 100
        }
        
        if fileName == queryLower {
            score += 200
        }
        
        let matchCount = queryLower.reduce(0) { count, char in
            fileName.contains(char) ? count + 1 : count
        }
        score += matchCount * 10
        
        return score
    }
}

class DocumentInteractionDelegate: NSObject, UIDocumentInteractionControllerDelegate {
    private let tempFileURL: URL
    private let uid: String
    private let fileName: String
    private weak var presentingViewController: UIViewController?
    private weak var manager: DocumentInteractionManager?
    
    init(tempFileURL: URL, uid: String, fileName: String, presentingViewController: UIViewController, manager: DocumentInteractionManager) {
        self.tempFileURL = tempFileURL
        self.uid = uid
        self.fileName = fileName
        self.presentingViewController = presentingViewController
        self.manager = manager
    }
    
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return presentingViewController ?? UIViewController()
    }
    
    func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
        appLogger.info("📱 文档预览已关闭")
        manager?.previewDidEnd()
        
        DispatchQueue.global().async {
            AppGroupDBManager.shared.updateAccessTime(uid: self.uid)
            appLogger.info("📅 已更新文件访问时间: \(self.fileName)")
        }
        
        cleanupTempFile()
    }
    
    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        appLogger.info("📱 打开方式菜单已关闭")
        manager?.previewDidEnd()
        cleanupTempFile()
    }
    
    func documentInteractionController(_ controller: UIDocumentInteractionController, didEndSendingToApplication application: String?) {
        appLogger.info("📤 已发送到应用: \(application ?? "未知")")
        manager?.previewDidEnd()
        
        DispatchQueue.global().async {
            AppGroupDBManager.shared.updateAccessTime(uid: self.uid)
            appLogger.info("📅 已更新文件访问时间: \(self.fileName)")
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            self.cleanupTempFile()
        }
    }
    
    private func cleanupTempFile() {
        DispatchQueue.global().async {
            do {
                if FileManager.default.fileExists(atPath: self.tempFileURL.path) {
                    try FileManager.default.removeItem(at: self.tempFileURL)
                    appLogger.info("🗑️ 临时文件已清理")
                }
            } catch {
                appLogger.error("❌ 清理临时文件失败: \(error)")
            }
        }
    }
}

struct DebugDatabaseView: View {
    @State private var dbLog = ""
    @State private var selectedTable = "file_mapping"
    @State private var configRecords: [GlobalConfigRecord] = []

    private let tableOptions = [
        ("file_mapping", "文件映射表"),
        ("global_config", "全局配置表")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("选择表:")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Picker("", selection: $selectedTable) {
                        ForEach(tableOptions, id: \.0) { option in
                            Text(option.1)
                                .tag(option.0)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedTable) {
                        refreshDBLog()
                    }

                    Spacer()
                }
                .padding()

                Divider()

                if selectedTable == "global_config" {
                    configTableView
                } else {
                    ScrollView {
                        Text(dbLog)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Button(action: refreshDBLog) {
                        Text("刷新")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(12)
                    }

                    if selectedTable == "file_mapping" {
                        Button(action: clearDB) {
                            Text("清理未落盘记录")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.red)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("数据库调试")
            .onAppear {
                refreshDBLog()
            }
        }
    }

    private var configTableView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Key")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Value")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Remark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))

            Divider()

            if configRecords.isEmpty {
                Spacer()
                Text("全局配置表当前为空")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(configRecords.enumerated()), id: \.element.id) { index, record in
                            HStack(spacing: 8) {
                                Text(record.key)
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(displayValue(for: record))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(record.remark.isEmpty ? "-" : record.remark)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color(.systemGray6))

                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func displayValue(for record: GlobalConfigRecord) -> String {
        if record.value.isEmpty {
            return "(空)"
        }
        if record.key == GlobalConfigKey.password {
            return "******"
        }
        return record.value
    }

    private func refreshDBLog() {
        switch selectedTable {
        case "file_mapping":
            dbLog = AppGroupDBManager.shared.fetchAllLog()
        case "global_config":
            configRecords = AppGroupDBManager.shared.fetchAllConfig()
        default:
            dbLog = "未知表"
        }
    }

    private func clearDB() {
        switch selectedTable {
        case "file_mapping":
            let records = AppGroupDBManager.shared.queryNonLocalVaultRecords()
            let ids = records.map { $0.id }
            if ids.isEmpty {
                appLogger.info("🔍 [调试页面] 文件映射表没有未落盘数据可清空")
            } else {
                _ = AppGroupDBManager.shared.deleteRecord(ids: ids)
                appLogger.info("🔍 [调试页面] 文件映射表已清空 \(ids.count) 条未落盘数据")
            }
        case "global_config":
            _ = AppGroupDBManager.shared.clearAllConfig()
            configRecords = AppGroupDBManager.shared.fetchAllConfig()
            appLogger.info("🔍 [调试页面] 全局配置表已清空")
        default:
            break
        }
        if selectedTable == "file_mapping" {
            dbLog = AppGroupDBManager.shared.fetchAllLog()
        }
    }
}

import CommonCrypto