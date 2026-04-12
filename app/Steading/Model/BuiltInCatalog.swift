import Foundation

/// Dummy catalog of macOS built-in server facilities that Steading
/// wraps rather than replaces — SMB, SSH, Firewall, Time Machine,
/// Content Caching, Screen Sharing, and so on. These are GUI
/// surfaces over existing native plumbing (`sharing`, `systemsetup`,
/// `socketfilterfw`, `pmset`, etc.), not reimplementations.
enum BuiltInCatalog {
    static let items: [CatalogItem] = [
        CatalogItem(
            id: "smb",
            kind: .builtIn,
            name: "File Sharing",
            symbol: "folder.badge.person.crop",
            subtitle: "SMB with per-share ACLs",
            summary: """
                Share folders over SMB. Wraps macOS's native `sharing` \
                command with a GUI over per-share ACL controls.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "time-machine",
            kind: .builtIn,
            name: "Time Machine Server",
            symbol: "clock.arrow.circlepath",
            subtitle: "Network backup destination",
            summary: """
                Offer this Mac as a Time Machine destination on the LAN. \
                Wraps the built-in Time Machine server facility.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "ssh",
            kind: .builtIn,
            name: "SSH / Remote Login",
            symbol: "terminal",
            subtitle: "Key-based remote shell",
            summary: """
                Remote login via SSH. Defaults: key-based only, no root \
                login, rate-limited. SSH plus Screen Sharing are \
                Steading's entire remote-access and recovery story.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "screen-sharing",
            kind: .builtIn,
            name: "Screen Sharing",
            symbol: "display.2",
            subtitle: "Apple Remote Desktop protocol",
            summary: """
                GUI recovery for when clicking through the UI is the \
                fastest way back from something having gone wrong.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "firewall",
            kind: .builtIn,
            name: "Firewall",
            symbol: "shield.lefthalf.filled",
            subtitle: "socketfilterfw + pf",
            summary: """
                Application firewall (`socketfilterfw`) and packet \
                filter (`pf`) rules. Context-aware warnings on footguns.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "printer-sharing",
            kind: .builtIn,
            name: "Printer Sharing",
            symbol: "printer",
            subtitle: "CUPS network printing",
            summary: """
                Share connected printers with other machines on the LAN.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "power",
            kind: .builtIn,
            name: "Power Management",
            symbol: "bolt.batteryblock",
            subtitle: "pmset 24/7 preset",
            summary: """
                Sensible power / wake defaults for 24/7 server \
                operation. Wraps `pmset`.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "content-caching",
            kind: .builtIn,
            name: "Content Caching",
            symbol: "externaldrive.badge.icloud",
            subtitle: "Apple content cache",
            summary: """
                Cache Apple software updates and iCloud content on the \
                LAN to save bandwidth.
                """,
            dependencies: [],
            optional: true
        ),
    ]
}
