import Foundation
import Testing
@testable import ZorofinCore

private func connection(_ url: String = "https://one.example/jellyfin", user: String = "viewer", token: String = "fixture-token") throws -> Session {
    Session(server: try ServerAddress(url), viewer: Viewer(id: user, name: "Viewer"), token: token, deviceID: "device-" + user)
}

@Suite("Saved servers and account isolation") struct SavedConnectionsTests {
    @Test func migratesSingleSessionWithoutLosingCredentialsOrDeviceIdentity() throws {
        let original = try connection()
        let legacy = try JSONEncoder().encode(original)
        let migrated = try JSONDecoder().decode(SavedConnections.self, from: legacy)
        #expect(migrated.accounts.count == 1)
        #expect(migrated.activeAccount?.session?.token == original.token)
        #expect(migrated.activeAccount?.session?.deviceID == original.deviceID)
        #expect(migrated.activeAccount?.server == original.server)
        let restored = try JSONDecoder().decode(SavedConnections.self, from: JSONEncoder().encode(migrated))
        #expect(restored.activeID == migrated.activeID)
    }
    @Test func sameUserIDOnDifferentServersRemainsIndependent() throws {
        var saved = SavedConnections()
        let a = saved.remember(try connection(), serverName: "One")
        let b = saved.remember(try connection("https://two.example", token: "second-token"), serverName: "Two")
        #expect(a != b)
        #expect(saved.servers.count == 2)
        try saved.select(a)
        #expect(saved.activeAccount?.session?.token == "fixture-token")
        #expect(saved.accounts.first { $0.id == b }?.session?.token == "second-token")
    }
    @Test func defaultPortAndTrailingSlashDoNotDuplicateAViewer() throws {
        var saved = SavedConnections()
        let a = saved.remember(try connection("https://ONE.example:443/jellyfin/"), serverName: "Old name")
        let b = saved.remember(try connection(token: "renewed-token"), serverName: "New name")
        #expect(a == b)
        #expect(saved.accounts.count == 1)
        #expect(saved.activeAccount?.session?.token == "renewed-token")
        #expect(saved.servers.first?.name == "New name")
    }
    @Test func basePathsAndNondefaultPortsRemainDistinct() throws {
        var saved = SavedConnections()
        for url in ["https://one.example/a", "https://one.example/b", "https://one.example:8443/a"] {
            saved.remember(try connection(url), serverName: "Same display name")
        }
        #expect(saved.servers.count == 3)
    }
    @Test func multipleViewersOnOneServerHaveIndependentTokens() throws {
        var saved = SavedConnections()
        let a = saved.remember(try connection(user: "a", token: "token-a"), serverName: "One")
        let b = saved.remember(try connection(user: "b", token: "token-b"), serverName: "One")
        #expect(saved.servers.count == 1)
        #expect(saved.servers[0].accounts.count == 2)
        saved.signOut(a)
        #expect(saved.accounts.first { $0.id == a }?.session == nil)
        #expect(saved.activeID == b)
        #expect(saved.activeAccount?.session?.token == "token-b")
        #expect(throws: ClientError.missingSession) { try saved.select(a) }
    }
    @Test func currentSignOutKeepsPlaceholderAndOtherServers() throws {
        var saved = SavedConnections()
        saved.remember(try connection(), serverName: "One")
        let b = saved.remember(try connection("https://two.example"), serverName: "Two")
        saved.signOut(b)
        #expect(saved.activeID == nil)
        #expect(saved.accounts.count == 2)
        #expect(saved.accounts.first?.session != nil)
        #expect(saved.accounts.last?.viewer.name == "Viewer")
        let restored = try JSONDecoder().decode(SavedConnections.self, from: JSONEncoder().encode(saved))
        #expect(restored.accounts.last?.session == nil)
        #expect(restored.activeID == nil)
    }
    @Test func reauthenticationReusesPlaceholderIdentity() throws {
        var saved = SavedConnections()
        let id = saved.remember(try connection(), serverName: "One")
        saved.signOut(id)
        #expect(saved.remember(try connection(token: "new-token"), serverName: "One") == id)
        #expect(saved.accounts.count == 1)
        #expect(saved.activeID == id)
    }
    @Test func removalDoesNotDeleteAnotherAccountOrServer() throws {
        var saved = SavedConnections()
        let a = saved.remember(try connection(), serverName: "One")
        let b = saved.remember(try connection("https://two.example"), serverName: "Two")
        saved.remove(a)
        #expect(saved.activeID == b)
        #expect(saved.servers.count == 1)
        saved.remove(b)
        #expect(saved.activeID == nil && saved.accounts.isEmpty)
    }
    @Test func visitOnlySelectionDoesNotDestroyRememberedAccounts() throws {
        var saved = SavedConnections()
        saved.remember(try connection(), serverName: "One")
        saved.clearSelection()
        let restored = try JSONDecoder().decode(SavedConnections.self, from: JSONEncoder().encode(saved))
        #expect(restored.activeID == nil && restored.accounts.count == 1)
        #expect(restored.accounts[0].session?.token == "fixture-token")
    }
    @Test func rejectsUnknownVersionAndCorruptIdentityRatherThanResetting() throws {
        var saved = SavedConnections()
        saved.remember(try connection(), serverName: "One")
        let data = try JSONEncoder().encode(saved)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        #expect(throws: ClientError.invalidResponse) {
            try JSONDecoder().decode(SavedConnections.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object["schemaVersion"] = 1
        var accounts = try #require(object["accounts"] as? [[String: Any]])
        accounts[0]["viewer"] = ["id": "different-user", "name": "Viewer"]
        object["accounts"] = accounts
        #expect(throws: ClientError.invalidResponse) {
            try JSONDecoder().decode(SavedConnections.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
    @Test func displayNameDoesNotRewriteTheChosenServer() throws {
        var saved = SavedConnections()
        saved.remember(try connection(), serverName: "Zorofin")
        #expect(saved.activeAccount?.server == (try connection()).server)
        #expect(saved.activeAccount?.serverName == "Zorofin")
    }
}
