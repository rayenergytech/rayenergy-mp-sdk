import Foundation

enum AcquisitionChannel {
    static func normalize(_ raw: Any?) throws -> String {
        guard let raw=raw, !(raw is NSNull) else{return "organic"}
        guard let text=raw as? String else{throw failure()}
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.isEmpty || ["organic","web","ogannic","unknown","undefined","null","未知","未上报","自然量"].contains(value.lowercased()){return "organic"}
        guard value.utf16.count<=64 else{throw failure()};return value
    }
    private static func failure()->NSError {NSError(domain:"AcquisitionChannel",code:1,userInfo:[NSLocalizedDescriptionKey:"channel must be a string of at most 64 characters"])}
}
