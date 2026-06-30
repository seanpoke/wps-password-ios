import SwiftUI
import OSLog
import Combine

let permissionTreeLogger = Logger(subsystem: "com.greenet.PasswordManager", category: "PermissionTree")

// MARK: - ViewModel

final class PermissionTreeViewModel: ObservableObject {
    @Published var rootNodes: [PermissionNode] = []
    @Published var selectedDNs: Set<String> = []
    @Published var expandedDNs: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isSubmitting = false
    @Published var submitResultMessage: String?

    func loadData(docId: String) {
        isLoading = true
        errorMessage = nil
        permissionTreeLogger.info("📂 开始加载权限树 | docId: \(docId, privacy: .public)")

        APIService.shared.fetchDocAuthTree(docId: docId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .success(let responseNodes):
                    let nodes = responseNodes.map { PermissionNode(response: $0) }
                    self.rootNodes = nodes
                    self.selectedDNs = self.collectAuthDNs(nodes)
                    permissionTreeLogger.info("✅ 权限树加载完成 | 根节点数: \(nodes.count) | 已授权DN数: \(self.selectedDNs.count)")
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    permissionTreeLogger.error("❌ 权限树加载失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func collectAuthDNs(_ nodes: [PermissionNode]) -> Set<String> {
        var dns = Set<String>()
        for node in nodes {
            if node.hasAuth {
                dns.insert(node.dn)
            }
            dns.formUnion(collectAuthDNs(node.children))
        }
        return dns
    }

    func checkboxState(for node: PermissionNode) -> CheckboxState {
        if node.isLeaf {
            return selectedDNs.contains(node.dn) ? .checked : .unchecked
        }

        let allDescendantDNs = collectAllDescendantDNs(node)
        let selectedCount = allDescendantDNs.filter { selectedDNs.contains($0) }.count

        if selectedCount == 0 {
            return .unchecked
        } else if selectedCount == allDescendantDNs.count {
            return .checked
        } else {
            return .partial
        }
    }

    func toggleNode(_ node: PermissionNode) {
        let currentState = checkboxState(for: node)
        let targetSelected: Bool

        switch currentState {
        case .unchecked, .partial:
            targetSelected = true
        case .checked:
            targetSelected = false
        }

        let descendantDNs = collectAllDescendantDNs(node)
        if targetSelected {
            selectedDNs.formUnion(descendantDNs)
        } else {
            selectedDNs.subtract(descendantDNs)
        }
    }

    func isExpanded(_ node: PermissionNode) -> Bool {
        expandedDNs.contains(node.dn)
    }

    func toggleExpand(_ node: PermissionNode) {
        if expandedDNs.contains(node.dn) {
            expandedDNs.remove(node.dn)
        } else {
            expandedDNs.insert(node.dn)
        }
    }

    private func collectAllDescendantDNs(_ node: PermissionNode) -> Set<String> {
        var dns = Set([node.dn])
        for child in node.children {
            dns.formUnion(collectAllDescendantDNs(child))
        }
        return dns
    }

    func collectSelectedDNs() -> (accountDnList: [String], deptDnList: [String]) {
        var accountDnList: [String] = []
        var deptDnList: [String] = []

        func traverse(_ nodes: [PermissionNode]) {
            for node in nodes {
                let state = checkboxState(for: node)
                switch state {
                case .unchecked:
                    continue
                case .checked:
                    if node.type == 1 {
                        accountDnList.append(node.dn)
                    } else {
                        deptDnList.append(node.dn)
                    }
                case .partial:
                    traverse(node.children)
                }
            }
        }

        traverse(rootNodes)
        return (accountDnList, deptDnList)
    }

    func submitAuth(docId: String) {
        let (accountDnList, deptDnList) = collectSelectedDNs()
        isSubmitting = true
        submitResultMessage = nil

        permissionTreeLogger.info("📤 提交权限更新 | docId: \(docId, privacy: .public) | accountDnList: \(accountDnList.count)条 | deptDnList: \(deptDnList.count)条")

        APIService.shared.updateDocAuth(docId: docId, accountDnList: accountDnList, deptDnList: deptDnList) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSubmitting = false
                switch result {
                case .success(let message):
                    self.submitResultMessage = message
                    permissionTreeLogger.info("✅ 权限更新提交成功 | message: \(message)")
                case .failure(let error):
                    self.submitResultMessage = "提交失败: \(error.localizedDescription)"
                    permissionTreeLogger.error("❌ 权限更新提交失败: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - 三态勾选框

struct CheckboxView: View {
    let state: CheckboxState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            switch state {
            case .unchecked:
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.gray.opacity(0.4), lineWidth: 1.5)
                    )
                    .frame(width: 20, height: 20)

            case .partial:
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.gray.opacity(0.4), lineWidth: 1.5)
                        )
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.blue)
                }
                .frame(width: 20, height: 20)

            case .checked:
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 20, height: 20)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 树节点视图

struct PermissionTreeNodeView: View {
    let node: PermissionNode
    @ObservedObject var viewModel: PermissionTreeViewModel
    let level: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                // 展开/收起按钮
                if !node.isLeaf {
                    Button(action: { viewModel.toggleExpand(node) }) {
                        Image(systemName: viewModel.isExpanded(node) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gray)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 16)
                }

                // 勾选框
                CheckboxView(
                    state: viewModel.checkboxState(for: node),
                    onTap: { viewModel.toggleNode(node) }
                )

                // 节点名称
                HStack(spacing: 4) {
                    Image(systemName: node.type == 0 ? "folder" : "person")
                        .font(.system(size: 12))
                        .foregroundColor(node.type == 0 ? .orange : .blue)
                    Text(node.name)
                        .font(.system(size: 14))
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.leading, CGFloat(level) * 20 + 8)
            .padding(.trailing, 8)

            // 子节点
            if !node.isLeaf && viewModel.isExpanded(node) {
                ForEach(node.children) { child in
                    PermissionTreeNodeView(
                        node: child,
                        viewModel: viewModel,
                        level: level + 1
                    )
                }
            }
        }
    }
}

// MARK: - 权限树主视图

struct PermissionTreeView: View {
    let docId: String
    @StateObject private var viewModel = PermissionTreeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行 + 提交按钮
            HStack {
                Text("文档权限信息")
                    .font(.headline)

                Spacer()

                if !viewModel.rootNodes.isEmpty {
                    Button(action: { viewModel.submitAuth(docId: docId) }) {
                        HStack(spacing: 4) {
                            if viewModel.isSubmitting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text("提交")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .disabled(viewModel.isSubmitting)
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)

            // 提交结果提示
            if let resultMsg = viewModel.submitResultMessage {
                Text(resultMsg)
                    .font(.system(size: 13))
                    .foregroundColor(resultMsg.hasPrefix("提交失败") ? .red : .green)
                    .padding(.bottom, 8)
            }

            if viewModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView("加载权限信息...")
                    Spacer()
                }
                .padding()
            } else if let error = viewModel.errorMessage {
                Text("加载失败: \(error)")
                    .font(.body)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if viewModel.rootNodes.isEmpty {
                Text("暂无权限信息")
                    .font(.body)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.rootNodes) { node in
                            PermissionTreeNodeView(
                                node: node,
                                viewModel: viewModel,
                                level: 0
                            )
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .onAppear {
            viewModel.loadData(docId: docId)
        }
    }
}
