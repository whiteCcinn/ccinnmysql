import Foundation
import Testing
@testable import MySQLKit

@Suite("SSH tunnel arguments")
struct SSHTunnelArgumentsTests {
    private func configuration(_ authentication: SSHTunnelConfiguration.Authentication) -> SSHTunnelConfiguration {
        SSHTunnelConfiguration(host: "bastion", port: 2222, username: authentication == .privateKey ? "" : "ops",
                               authentication: authentication, privateKeyPath: "~/.ssh/id_ed25519")
    }

    // With `ControlMaster auto` in ~/.ssh/config the app's tunnel became the shared master: closing its window broke the
    // other windows and the user's terminal sessions multiplexed over it. `ControlMaster=no` alone is not enough: ssh
    // then joins a master the user already runs at their ControlPath as a mux client. That master owns the forwarded
    // port, which outlives the tunnel (and every connect adds another), and the profile's authentication is never used.
    // So the tunnel neither becomes nor uses a master: `ControlPath=none` (only this ssh; the user's sessions keep theirs).
    @Test(arguments: SSHTunnelConfiguration.Authentication.allCases)
    func aTunnelNeverUsesOrBecomesASharedControlMaster(authentication: SSHTunnelConfiguration.Authentication) throws {
        let arguments = try SSHTunnel.arguments(for: configuration(authentication), localPort: 40000,
                                                remote: Endpoint(host: "db.internal", port: 3306))
        let options = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-o" }.map(\.1)
        #expect(options.filter { $0.lowercased().hasPrefix("controlmaster") } == ["ControlMaster=no"], "\(arguments)")
        #expect(options.filter { $0.lowercased().hasPrefix("controlpath") } == ["ControlPath=none"], "\(arguments)")
        // No other way to name a control socket or keep a master alive: `-S` sets ControlPath, `-M` makes a master.
        #expect(!arguments.contains("-S") && !arguments.contains("-M"), "\(arguments)")
        #expect(!arguments.contains { $0.localizedCaseInsensitiveContains("ControlPersist") }, "\(arguments)")
        #expect(arguments.filter { $0.localizedCaseInsensitiveContains("ControlPath") } == ["ControlPath=none"], "\(arguments)")
        // ssh reads everything after the destination as the remote command, so options must come before it.
        let destination = try #require(arguments.last)
        #expect(destination.hasSuffix("bastion"))
        for option in ["ControlMaster=no", "ControlPath=none"] {
            let position = try #require(arguments.firstIndex(of: option), "\(arguments)")
            #expect(position > 0 && arguments[position - 1] == "-o")
            #expect(position < arguments.count - 1)
        }
    }
}
