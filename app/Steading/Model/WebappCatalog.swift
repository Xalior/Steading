import Foundation

/// Dummy Webapps catalog for the PoC. Reflects the v1 list in
/// DESIGN.md § Webapps catalog. Webapps have no daemon of their own;
/// they're files behind a Caddy virtual host served by shared
/// infrastructure.
enum WebappCatalog {
    static let items: [CatalogItem] = [
        CatalogItem(
            id: "mediawiki",
            kind: .webapp,
            name: "MediaWiki",
            symbol: "books.vertical",
            subtitle: "Wiki platform",
            summary: """
                The wiki platform Wikipedia runs on. Lives in a directory \
                behind its own Caddy virtual host, backed by the shared \
                MySQL.
                """,
            dependencies: ["PHP-FPM", "MySQL"],
            optional: false
        ),
        CatalogItem(
            id: "wordpress",
            kind: .webapp,
            name: "WordPress",
            symbol: "doc.richtext",
            subtitle: "CMS / blog",
            summary: """
                The classic PHP content management system. Each instance \
                is its own directory and its own Caddy vhost, backed by \
                a dedicated database inside the shared MySQL.
                """,
            dependencies: ["PHP-FPM", "MySQL"],
            optional: false
        ),
        CatalogItem(
            id: "dokuwiki",
            kind: .webapp,
            name: "DokuWiki",
            symbol: "text.book.closed",
            subtitle: "Flat-file wiki",
            summary: """
                File-based wiki — no database required. Just needs \
                PHP-FPM and its own Caddy virtual host.
                """,
            dependencies: ["PHP-FPM"],
            optional: false
        ),
    ]
}
