import Foundation

/// All live built-in service runners, keyed by the matching
/// `CatalogItem.id` in `BuiltInCatalog`.
enum BuiltInServiceRegistry {
    static let all: [String: BuiltInServiceRunner] = [
        BuiltInServiceRunner.ssh.id:             .ssh,
        BuiltInServiceRunner.smb.id:             .smb,
        BuiltInServiceRunner.screenSharing.id:   .screenSharing,
        BuiltInServiceRunner.contentCaching.id:  .contentCaching,
        BuiltInServiceRunner.firewall.id:        .firewall,
        BuiltInServiceRunner.printerSharing.id:  .printerSharing,
        BuiltInServiceRunner.power.id:           .power,
        BuiltInServiceRunner.timeMachine.id:     .timeMachine,
    ]

    static func runner(for id: String) -> BuiltInServiceRunner? {
        all[id]
    }
}

extension BuiltInServiceRunner {

    // MARK: - SSH / Remote Login

    static let ssh = BuiltInServiceRunner(
        id: "ssh",
        displayName: "Remote Login (SSH)",
        detectionNote:
            "User-override state of com.openssh.sshd in launchd's system domain (via launchctl print-disabled).",
        readState: {
            await launchdSystemOverrideState(label: "com.openssh.sshd")
        },
        enableCommands:  [["/usr/sbin/systemsetup", "-setremotelogin", "on"]],
        disableCommands: [["/usr/sbin/systemsetup", "-f", "-setremotelogin", "off"]]
    )

    // MARK: - SMB / File Sharing

    static let smb = BuiltInServiceRunner(
        id: "smb",
        displayName: "File Sharing (SMB)",
        detectionNote:
            "User-override state of com.apple.smbd in launchd's system domain. Running the daemon is necessary but not sufficient — shares still need to be configured.",
        readState: {
            await launchdSystemOverrideState(label: "com.apple.smbd")
        },
        // `launchctl enable` only flips the override; `kickstart -k`
        // actually starts (or replaces) the daemon process right now.
        enableCommands: [
            ["/bin/launchctl", "enable",  "system/com.apple.smbd"],
            ["/bin/launchctl", "kickstart", "-k", "system/com.apple.smbd"],
        ],
        // `disable` sets the override; `kill` delivers a signal to the
        // running job so it stops immediately rather than at next boot.
        disableCommands: [
            ["/bin/launchctl", "disable", "system/com.apple.smbd"],
            ["/bin/launchctl", "kill", "SIGTERM", "system/com.apple.smbd"],
        ]
    )

    // MARK: - Screen Sharing

    static let screenSharing = BuiltInServiceRunner(
        id: "screen-sharing",
        displayName: "Screen Sharing",
        detectionNote:
            "User-override state of com.apple.screensharing in launchd's system domain.",
        readState: {
            await launchdSystemOverrideState(label: "com.apple.screensharing")
        },
        enableCommands: [
            ["/bin/launchctl", "enable",  "system/com.apple.screensharing"],
            ["/bin/launchctl", "kickstart", "-k", "system/com.apple.screensharing"],
        ],
        disableCommands: [
            ["/bin/launchctl", "disable", "system/com.apple.screensharing"],
            ["/bin/launchctl", "kill", "SIGTERM", "system/com.apple.screensharing"],
        ]
    )

    // MARK: - Content Caching

    static let contentCaching = BuiltInServiceRunner(
        id: "content-caching",
        displayName: "Content Caching",
        detectionNote:
            "`/usr/bin/AssetCacheManagerUtil status` → Activated flag.",
        readState: {
            let result = await ProcessRunner.run("/usr/bin/AssetCacheManagerUtil", ["status"])
            guard result.ok else {
                return .error("AssetCacheManagerUtil exit \(result.exitCode)")
            }
            let text = result.stdout
            if text.contains("Activated: true")  { return .enabled  }
            if text.contains("Activated: false") { return .disabled }
            return .unknown(reason: "Could not parse AssetCacheManagerUtil output.")
        },
        enableCommands:  [["/usr/bin/AssetCacheManagerUtil", "activate"]],
        disableCommands: [["/usr/bin/AssetCacheManagerUtil", "deactivate"]]
    )

    // MARK: - Firewall (socketfilterfw)

    static let firewall = BuiltInServiceRunner(
        id: "firewall",
        displayName: "Firewall",
        detectionNote:
            "`/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`.",
        readState: {
            let result = await ProcessRunner.run(
                "/usr/libexec/ApplicationFirewall/socketfilterfw",
                ["--getglobalstate"]
            )
            guard result.ok else {
                return .error("socketfilterfw exit \(result.exitCode)")
            }
            let out = result.stdout.lowercased()
            // Output is literally "Firewall is enabled. (State = 1)"
            // or "Firewall is disabled. (State = 0)".
            if out.contains("disabled") { return .disabled }
            if out.contains("enabled")  { return .enabled  }
            return .unknown(reason: "Could not parse socketfilterfw output.")
        },
        enableCommands: [[
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            "--setglobalstate", "on"
        ]],
        disableCommands: [[
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            "--setglobalstate", "off"
        ]]
    )

    // MARK: - Printer Sharing (CUPS)

    static let printerSharing = BuiltInServiceRunner(
        id: "printer-sharing",
        displayName: "Printer Sharing",
        detectionNote:
            "`cupsctl` → _share_printers value.",
        readState: {
            let result = await ProcessRunner.run("/usr/sbin/cupsctl")
            guard result.ok else {
                return .error("cupsctl exit \(result.exitCode)")
            }
            for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("_share_printers=") else { continue }
                let value = line.dropFirst("_share_printers=".count)
                if value == "1" { return .enabled  }
                if value == "0" { return .disabled }
            }
            return .unknown(reason: "_share_printers not present in cupsctl output.")
        },
        enableCommands:  [["/usr/sbin/cupsctl", "--share-printers"]],
        disableCommands: [["/usr/sbin/cupsctl", "--no-share-printers"]]
    )

    // MARK: - Power Management

    static let power = BuiltInServiceRunner(
        id: "power",
        displayName: "Power Management",
        detectionNote:
            "`pmset -g` current values. The 24/7 preset is `sleep=0` + `womp=1`.",
        readState: {
            let result = await ProcessRunner.run("/usr/bin/pmset", ["-g"])
            guard result.ok else {
                return .error("pmset exit \(result.exitCode)")
            }
            let sleep = pmsetValue(for: "sleep",         in: result.stdout) ?? "?"
            let womp  = pmsetValue(for: "womp",          in: result.stdout) ?? "?"
            let apo   = pmsetValue(for: "autopoweroff",  in: result.stdout) ?? "?"
            let summary = "sleep=\(sleep)  ·  womp=\(womp)  ·  autopoweroff=\(apo)"
            // "24/7 preset" conceptually: no idle sleep, wake-on-LAN on.
            let serverShaped: Bool? = (sleep == "?" || womp == "?")
                ? nil
                : (sleep == "0" && womp == "1")
            return .custom(summary: summary, isOn: serverShaped)
        },
        // Applying a 24/7 preset is a multi-command change; the UI
        // currently surfaces the observed values only.
        enableCommands:  nil,
        disableCommands: nil
    )

    // MARK: - Time Machine Server

    static let timeMachine = BuiltInServiceRunner(
        id: "time-machine",
        displayName: "Time Machine Server",
        detectionNote:
            "Whether this Mac is *serving* Time Machine needs SMB share inspection for the TM flag; not yet wired up.",
        readState: {
            .unknown(reason: "Requires multi-source detection; not yet implemented.")
        },
        enableCommands:  nil,
        disableCommands: nil
    )

    // MARK: - Helpers

    /// Live: ask `launchctl print-disabled system` for the override
    /// state of a named LaunchDaemon label. Unprivileged and stable.
    private static func launchdSystemOverrideState(label: String) async -> BuiltInServiceState {
        let result = await ProcessRunner.run("/bin/launchctl", ["print-disabled", "system"])
        guard result.ok else {
            return .error("launchctl print-disabled exit \(result.exitCode)")
        }
        return parseLaunchdOverride(output: result.stdout, label: label)
    }

    /// Pure parser for `launchctl print-disabled system` output.
    /// Lines look like:
    ///
    ///     "com.openssh.sshd" => enabled
    ///     "com.apple.smbd"   => disabled
    ///
    /// Exposed so tests call it directly against canned outputs.
    static func parseLaunchdOverride(output: String, label: String) -> BuiltInServiceState {
        let needle = "\"\(label)\""
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Require the quoted label to be the line's opening token
            // so that e.g. "com.openssh.sshd-agent" doesn't match a
            // lookup for "com.openssh.sshd".
            guard line.hasPrefix(needle + " ") || line.hasPrefix(needle + "=") else {
                continue
            }
            if line.contains("=> enabled")  { return .enabled  }
            if line.contains("=> disabled") { return .disabled }
        }
        return .unknown(reason: "\(label) not present in launchctl override list.")
    }

    /// Pure extractor for a `pmset -g` value. Matches a line whose
    /// first token equals `key` and returns the following token.
    ///
    ///     " sleep                0 (sleep prevented by powerd)"  ->  "0"
    ///     " womp                 1"                              ->  "1"
    static func pmsetValue(for key: String, in output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == Substring(key) else { continue }
            return String(parts[1])
        }
        return nil
    }
}
