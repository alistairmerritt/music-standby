import Foundation

/// The words in Second Chair's menu on the Mac. The Mac's menu shows them,
/// and the iPhone's first run draws them in its pictures of that menu, so
/// the two can't drift apart (first run V2, 16 November 2026).
public enum MacMenuText {
    public static let onThisMac = "On This Mac"
    public static let connected = "Connected"
    public static let iPhone = "iPhone"
    public static let notPaired = "Not paired"
    public static let paired = "Paired"

    public static let pairIPhone = "Pair iPhone…"
    public static let unpairIPhone = "Unpair iPhone"
    public static let typeThisOnIPhone = "Type this in Second Chair on your iPhone."
    public static func wantsToShow(_ phoneName: String) -> String { "“\(phoneName)” wants to show this Mac’s music." }
    public static let allow = "Allow"
    public static let dontAllow = "Don’t Allow"

    public static let continueListening = "Continue Listening"
    public static let connectToMusicNote = "Connect Second Chair to Music so your music can move between this Mac and your iPhone, with your Up Next queue."
    public static let connectToMusic = "Connect to Music…"
    public static let musicCodeNote = "In Music, select Second Chair under Devices, then enter this code:"
    public static let connectedToMusicNote = "Connected to Music. Your music can move between this Mac and your iPhone."
    public static let continueFromIPhone = "Continue from iPhone"
    public static let cancel = "Cancel"
}
