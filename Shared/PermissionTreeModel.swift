import Foundation

// MARK: - API 响应模型

struct PermissionNodeResponse: Codable {
    let dn: String
    let type: Int       // 0=部门, 1=员工
    let name: String
    let account: String?
    let hasAuth: Bool
    let deptList: [PermissionNodeResponse]?
    let employList: [PermissionNodeResponse]?
}

// MARK: - 统一展示节点

struct PermissionNode: Identifiable {
    var id: String { dn }
    let dn: String
    let type: Int
    let name: String
    let account: String?
    let hasAuth: Bool
    let children: [PermissionNode]

    init(response: PermissionNodeResponse) {
        self.dn = response.dn
        self.type = response.type
        self.name = response.name
        self.account = response.account
        self.hasAuth = response.hasAuth

        var children: [PermissionNode] = []
        if let deptList = response.deptList {
            children.append(contentsOf: deptList.map { PermissionNode(response: $0) })
        }
        if let employList = response.employList {
            children.append(contentsOf: employList.map { PermissionNode(response: $0) })
        }
        self.children = children
    }

    var isLeaf: Bool { children.isEmpty }
}

// MARK: - 勾选框状态

enum CheckboxState {
    case unchecked
    case partial
    case checked
}
