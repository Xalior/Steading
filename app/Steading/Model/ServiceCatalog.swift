import Foundation

/// Dummy Services catalog for the PoC. One blessed implementation
/// per category — no "Caddy or Nginx" decision trees — so that
/// integration stays tight and the test surface is bounded.
enum ServiceCatalog {
    static let items: [CatalogItem] = [
        CatalogItem(
            id: "caddy",
            kind: .service,
            name: "Caddy",
            symbol: "globe",
            subtitle: "Web server / reverse proxy",
            summary: """
                HTTP/HTTPS ingress. Terminates TLS, routes virtual hosts, \
                serves static files, and proxies upstream services. Every \
                Steading webapp lives behind a Caddy virtual host.
                """,
            dependencies: [],
            optional: false
        ),
        CatalogItem(
            id: "php-fpm",
            kind: .service,
            name: "PHP-FPM",
            symbol: "chevron.left.forwardslash.chevron.right",
            subtitle: "PHP runtime",
            summary: """
                FastCGI Process Manager for PHP. Shared across every PHP \
                webapp Steading manages — DokuWiki, MediaWiki, WordPress, \
                phpMyAdmin.
                """,
            dependencies: [],
            optional: false
        ),
        CatalogItem(
            id: "mysql",
            kind: .service,
            name: "MySQL",
            symbol: "cylinder.split.1x2",
            subtitle: "Relational database",
            summary: """
                Relational database for webapps that need one. Bound to \
                loopback by default; admin credentials kept in the \
                Keychain.
                """,
            dependencies: [],
            optional: false
        ),
        CatalogItem(
            id: "redis",
            kind: .service,
            name: "Redis",
            symbol: "bolt.square",
            subtitle: "Key-value / cache store",
            summary: """
                In-memory key-value store for caching and session data. \
                Loopback-only by default.
                """,
            dependencies: [],
            optional: false
        ),
        CatalogItem(
            id: "tailscale",
            kind: .service,
            name: "Tailscale",
            symbol: "network",
            subtitle: "Overlay networking",
            summary: """
                WireGuard-based overlay network. Optional — frequently \
                already installed by the owner for their own use. \
                Steading adopts an existing install rather than \
                duplicating it.
                """,
            dependencies: [],
            optional: true
        ),
        CatalogItem(
            id: "stalwart",
            kind: .service,
            name: "Stalwart",
            symbol: "envelope",
            subtitle: "Mail server (SMTP / IMAP / JMAP)",
            summary: """
                All-in-one mail server. Shipped via the \
                xalior/homebrew-steading tap since it isn't in \
                homebrew-core. Optional; not foundational.
                """,
            dependencies: [],
            optional: true
        ),
    ]
}
