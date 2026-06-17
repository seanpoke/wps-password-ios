# iOS 加密文档权限管理系统全新规格书 (Share Extension 纯净版)

## 1. 运行环境与 Target 工程树 (Engineering Tree)

- **最低支持系统**：iOS 18.0（当前测试环境：iPhone 13 / iOS 26.5）
- **完全编译要求**：Swift 6+ 严格并发检查（Strict Concurrency Checking），100% 纯 SwiftUI 状态机驱动。
- **物理工程 Target 树结构**：
  ├── PasswordManager (主 App Target, BundleID: com.sean.PasswordManager)
  ├── DocumentShareExtension (分享扩展 Target, BundleID: com.sean.PasswordManager.DocumentShareExtension)
  └── Shared (共享代码文件夹, 必须挂载至上述两个 Target 的 Compile Sources)

## 2. 跨进程共享数据地下通道 (App Group WAL DB)

- **共享容器 ID**：`group.com.sean.passwordmanager`
- **SQLite 绝对路径**：共享沙盒下的 `Documents/file_mapping.sqlite`
- **并发控制底线**：强制注入 `PRAGMA journal_mode=WAL;`，设置 `busy_timeout = 2000;` 毫秒。
- **标准化去噪**：主键 `file_name` 执行任何 CRUD 操作前，必须强制 `.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`。

## 3. 全屏 SwiftUI 状态机生命周期 (State Machine)

整个插件严禁引入 UIKit 的 `UIAlertController` 模态弹窗，由一个附带 `@MainActor` 隔离的四状态机驱动：
`enum ActionState { case identifying, syncConfirm, passwordCapture, assetList }`

- **流出查看流（状态 A: .identifying）**：全屏绿色背景。校验前 4 字节魔数 `50 4B 03 04` 并浅扫描 Central Directory（包含 `word/` 补齐 `.docx`；`xl/` 补齐 `.xlsx`；`ppt/` 补齐 `.pptx`）。点击确认，向系统 `UIPasteboard.general` 写入密码并注入 60 秒硬性自毁，通过系统级 Open-In 拉起 WPS，最后退出插件。
- **回流同步流（状态 B: .syncConfirm）**：全屏蓝色背景。WPS 二次分享回传命中老资产时触发，展现 `[ 确定同步覆盖 ]` 和 `[ 另存为新文件 ]` 两大尺寸物理按钮。

## 4. 密集计算防爆盾牌 (Jetsam & Watchdog Mitigation)

- **内存死刑线 (30MB)**：禁止使用 `Data(contentsOf:)`。必须使用 `FileHandle` 将单次解密缓冲区死卡在 **8MB** 以内。解密分块循环体内部必须硬编码 `autoreleasepool`，处理完立刻显式置空临时变量。
- **时间死刑线 (3s)**：解密 Task 必须运行在后台异步线程，在 8MB 循环体首行埋入 `Task.isCancelled`。文件 ≤ 100MB 限时 5 秒；100MB \~ 500MB 限时 10 秒。超时未命中立刻调用 `task.cancel()` 协作式平滑断流，规避系统 SIGKILL 强杀。

