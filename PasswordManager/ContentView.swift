import SwiftUI

struct ContentView: View {
    @State private var testResultLog: String = "等待测试..."
    @State private var isSuccess: Bool = false
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "network")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("地下通道（第一阶段）测试")
                .font(.title2)
                .bold()
            
            Button(action: {
                let passwordHash = "SecLink#2026".sha256().map { String(format: "%02X", $0) }.joined()
                AppGroupDBManager.shared.saveFileMapping(
                    fileName: "TEST_DOC.DOCX",
                    uid: "LDAP_SEAN_999",
                    passwordHash: passwordHash,
                    fileSize: 102400,
                    isLocalVault: 1
                )
                
                let logs = AppGroupDBManager.shared.fetchAllLog()
                withAnimation {
                    testResultLog = logs
                    isSuccess = true
                }
            }) {
                Text("点击测试：单向写入加密资产")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(12)
                    .padding(.horizontal, 40)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text("测试日志反馈：")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Text(testResultLog)
                    .font(.body.monospaced())
                    .foregroundColor(isSuccess ? .green : .primary)
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 20)
        }
        .padding()
    }
}

import CommonCrypto