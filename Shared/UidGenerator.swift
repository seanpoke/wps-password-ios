import Foundation

final class UidGenerator {
    
    static let shared = UidGenerator()
    
    private init() {}
    
    func createUid() -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let guid = UUID().uuidString
        return "\(timestamp)_\(guid)"
    }
}