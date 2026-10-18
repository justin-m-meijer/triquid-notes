import Foundation

/// Constants shared by the Share Extension and the main Trinote app.
enum SharedImportConstants {
    static let appGroupIdentifier = "group.com.justinmeijer.nl.liquid-notes"
    /// Its own scheme: the original Trinote app registers `trinote`, and iOS may open that app
    /// instead of this one.
    static let hostURLScheme = "triquidnotes"
    static let hostURLHost = "share-import"
    static let hostOpenURL = URL(string: "triquidnotes://share-import")!

    static let metadataFileName = "pending-share-import.json"
    static let binaryFileName = "pending-share-import.bin"
}
