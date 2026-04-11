import Foundation

// MARK: - Entry point
//
// The privileged helper runs as root under launchd — it's spawned
// on-demand when the main app opens an `NSXPCConnection` to the
// mach service name advertised in our embedded LaunchDaemon plist.
//
// The listener stays alive for as long as launchd keeps the process
// around. launchd will tear the process down when the last client
// disconnects and idle timeout expires.

let delegate = PrivHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: SteadingPrivHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// Run forever — launchd controls lifetime.
RunLoop.main.run()
