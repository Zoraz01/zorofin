import Foundation
import Testing
@testable import ZorofinCore

private actor SettingsTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw ClientError.network }
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private func settingsClient(_ transport: SettingsTransport, address: String = "https://media.example/base", viewer: String = "viewer") throws -> JellyfinClient {
    let server = try ServerAddress(address)
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"),
        session: .init(server: server, viewer: .init(id: viewer, name: "Viewer"), token: "fixture-token", deviceID: "fixture"), transport: transport)
}
private func user(_ config: [String: JSONValue] = [:], editable: Bool = true, id: String = "viewer") throws -> String {
    let data = try JSONEncoder().encode(["Id": JSONValue.string(id), "Name": .string("Viewer"), "HasPassword": .bool(true),
        "Configuration": .object(config), "Policy": .object(["EnableUserPreferenceAccess": .bool(editable)])])
    return String(decoding: data, as: UTF8.self)
}
private func alertBody(id: String = "viewer") -> String {
    #"{"account":{"id":""# + id + #"","name":"Viewer"},"email":{"enabled":false,"maskedAddress":""},"push":{"enabled":false,"server":"https://alerts.example"}}"#
}

@Suite("Native settings account and write boundaries") struct NativeSettingsTests {
    @Test func configurationSavePreservesFreshUneditedAndUnknownFields() async throws {
        let baseline = ViewerSettings(name: "Viewer", configuration: ["SubtitleMode":.string("Default"),"OrderedViews":.array([.string("old")])])
        let latest: [String:JSONValue] = ["SubtitleMode":.string("Default"),"OrderedViews":.array([.string("new")]),
            "FutureField":.object(["fraction":.double(0.25),"nothing":.null]),"OtherToggle":.bool(true)]
        var confirmed = latest; confirmed["SubtitleMode"] = .string("Smart")
        let transport = SettingsTransport([(200,try user(latest)),(204,""),(200,try user(confirmed))])
        let saved = try await settingsClient(transport).saveViewerConfiguration(changes:["SubtitleMode":.string("Smart")],baseline:baseline)
        #expect(saved.configuration == confirmed)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET","POST","GET"])
        #expect(requests[1].url?.path == "/base/Users/Configuration")
        #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL:false)?.queryItems == [.init(name:"userId",value:"viewer")])
        #expect(try JSONDecoder().decode([String:JSONValue].self,from:requests[1].httpBody!) == confirmed)
        #expect(requests.allSatisfy { $0.url?.host == "media.example" && $0.value(forHTTPHeaderField:"Authorization")?.contains("fixture-token") == true })
    }
    @Test func changedFieldConflictPreventsOverwrite() async throws {
        let transport=SettingsTransport([(200,try user(["SubtitleMode":.string("Always")]))])
        let baseline=ViewerSettings(name:"Viewer",configuration:["SubtitleMode":.string("Default")])
        await #expect(throws:SettingsError.changedElsewhere) {
            try await settingsClient(transport).saveViewerConfiguration(changes:["SubtitleMode":.string("Smart")],baseline:baseline)
        }
        #expect(await transport.requests.count == 1)
    }
    @Test func readOnlyAccountNeverWrites() async throws {
        let transport=SettingsTransport([(200,try user(editable:false))])
        await #expect(throws:ClientError.forbidden) {
            try await settingsClient(transport).saveViewerConfiguration(changes:["EnableNextEpisodeAutoPlay":.bool(true)],baseline:.init(name:"Viewer"))
        }
        #expect(await transport.requests.count == 1)
    }
    @Test(arguments:["Policy","IsAdministrator","OrderedViews","UnknownPreference"])
    func arbitraryFieldsCannotBeWritten(_ key:String) async throws {
        let transport=SettingsTransport([])
        await #expect(throws:SettingsError.invalidInput) {
            try await settingsClient(transport).saveViewerConfiguration(changes:[key:.bool(true)],baseline:.init(name:"Viewer"))
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func unchangedConfigurationMakesNoPost() async throws {
        let transport=SettingsTransport([(200,try user())])
        _ = try await settingsClient(transport).saveViewerConfiguration(changes:[:],baseline:.init(name:"Viewer"))
        #expect(await transport.requests.count == 1)
    }
    @Test(arguments:[(500,""),(200,"{}")])
    func lostOrUnexpectedReceiptDoesNotRetry(_ response:(Int,String)) async throws {
        let transport=SettingsTransport([(200,try user()),response])
        await #expect(throws:SettingsError.unconfirmed) {
            try await settingsClient(transport).saveViewerConfiguration(changes:["SubtitleMode":.string("None")],baseline:.init(name:"Viewer"))
        }
        #expect(await transport.requests.count == 2)
    }
    @Test func successStatusWithoutConfirmedValuesIsNotSaved() async throws {
        let transport=SettingsTransport([(200,try user()),(204,""),(200,try user())])
        await #expect(throws:SettingsError.unconfirmed) {
            try await settingsClient(transport).saveViewerConfiguration(changes:["SubtitleMode":.string("None")],baseline:.init(name:"Viewer"))
        }
        #expect(await transport.requests.count == 3)
    }
    @Test func passwordChangeUsesCurrentPasswordAndBoundViewer() async throws {
        let transport=SettingsTransport([(200,try user()),(204,"")])
        try await settingsClient(transport).changeOwnPassword(current:"old fixture",new:"new fixture")
        let requests=await transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].url?.path == "/base/Users/Password")
        #expect(requests[1].url?.query == "userId=viewer")
        #expect(try JSONDecoder().decode([String:JSONValue].self,from:requests[1].httpBody!) == ["CurrentPw":.string("old fixture"),"NewPw":.string("new fixture"),"ResetPassword":.bool(false)])
    }
    @Test func emptyPasswordNeverClearsAccountPassword() async throws {
        let transport=SettingsTransport([])
        await #expect(throws:SettingsError.invalidInput) { try await settingsClient(transport).changeOwnPassword(current:"old",new:"") }
        #expect(await transport.requests.isEmpty)
    }
    @Test func wrongViewerAndCrossServerReadsFailClosed() async throws {
        let transport=SettingsTransport([(200,try user(id:"another"))])
        let client=try settingsClient(transport)
        await #expect(throws:ClientError.invalidResponse) { try await client.viewerSettings() }
        let misplaced=JellyfinClient(server:try ServerAddress("https://other.example"),identity:client.identity,session:client.session,transport:transport)
        await #expect(throws:ClientError.unsafeURL) { try await misplaced.changeOwnPassword(current:"old",new:"new") }
        #expect(await transport.requests.count == 1)
    }
    @Test func profileImageIsBase64WithImageContentTypeAndNoCredentialInURL() async throws {
        let transport=SettingsTransport([(200,try user()),(204,"")])
        let data=Data([0xff,0xd8,0xff,0xd9])
        try await settingsClient(transport).updateOwnProfileImage(jpeg:data)
        let request=await transport.requests[1]
        #expect(request.url?.path == "/base/UserImage")
        #expect(request.url?.query == "userId=viewer")
        #expect(request.value(forHTTPHeaderField:"Content-Type") == "image/jpeg")
        #expect(request.httpBody == Data(data.base64EncodedString().utf8))
    }
    @Test func oversizedProfileImageDoesNotSend() async throws {
        let transport=SettingsTransport([])
        await #expect(throws:SettingsError.invalidInput) { try await settingsClient(transport).updateOwnProfileImage(jpeg:Data(repeating:0,count:2*1024*1024+1)) }
        #expect(await transport.requests.isEmpty)
    }
    @Test func notificationReadsVerifyAccountOwnership() async throws {
        let transport=SettingsTransport([(200,alertBody(id:"other"))])
        await #expect(throws:ClientError.invalidResponse) { try await settingsClient(transport).requestAlertSettings() }
        #expect(await transport.requests[0].value(forHTTPHeaderField:"X-Jellyfin-Token") == "fixture-token")
    }
    @Test func notificationActionsAreExplicitSinglePostsWithoutUserOverride() async throws {
        let transport=SettingsTransport([(200,alertBody()),(503,"")])
        let client=try settingsClient(transport)
        _ = try await client.updateRequestAlerts(.saveEmail,email:"fixture@example.test")
        await #expect(throws:SettingsError.unconfirmed) { try await client.updateRequestAlerts(.testEmail) }
        let requests=await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/base/support/request-alerts/email/save")
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.query == nil })
        #expect(try JSONDecoder().decode([String:String].self,from:requests[0].httpBody!) == ["email":"fixture@example.test"])
    }
    @Test func unknownJSONSurvivesRoundTrip() throws {
        let data=Data(#"{"flag":true,"count":4,"ratio":0.125,"unset":null,"list":["a",false]}"#.utf8)
        let value=try JSONDecoder().decode(JSONValue.self,from:data)
        #expect(try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(value)) == value)
    }
}

@Suite("Native preference persistence and playback") struct NativePreferenceTests {
    @Test func settingsSurviveRelaunchAndRemainIsolated() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let server=try ServerAddress("https://media.example/base")
        var value=NativePreferences(); value.bitrate=20_000_000;value.skipForward=60;value.showTitles=false
        try await NativePreferenceStore(root:root).save(value,server:server,viewerID:"one")
        let restored=NativePreferenceStore(root:root)
        #expect(try await restored.load(server:server,viewerID:"one") == value)
        #expect(try await restored.load(server:server,viewerID:"two") == .init())
        #expect(try await restored.load(server:ServerAddress("https://media.example/other"),viewerID:"one") == .init())
        let filename=try #require(FileManager.default.contentsOfDirectory(atPath:root.path).first)
        #expect(!filename.contains("media") && !filename.contains("one"))
    }
    @Test func tvDefaultsPersistAndIsolateViewersWithoutFilesystemWrites() async throws {
        let suite = "org.zorofin.tests.preferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try ServerAddress("https://media.example/base")
        var value = NativePreferences(); value.homeScreenPreviews = false; value.bitrate = 8_000_000
        let store = NativePreferenceStore(defaultsSuiteName: suite)
        try await store.save(value, server: server, viewerID: "one")
        let restored = NativePreferenceStore(defaultsSuiteName: suite)
        #expect(try await restored.load(server: server, viewerID: "one") == value)
        #expect(try await restored.load(server: server, viewerID: "two") == .init())
        #expect(try await restored.load(server: ServerAddress("https://media.example/other"), viewerID: "one") == .init())
        let domain = try #require(defaults.persistentDomain(forName: suite))
        #expect(domain.count == 1)
        let key = try #require(domain.keys.first)
        #expect(!key.contains("media") && !key.contains("one"))
        #expect(try #require(domain[key] as? Data).count < 1024)
        var invalid = value; invalid.bitrate = -1
        await #expect(throws: SettingsError.invalidInput) { try await store.save(invalid, server: server, viewerID: "one") }
        #expect(try await restored.load(server: server, viewerID: "one") == value)
        defaults.set(Data(repeating: 0, count: 128 * 1024), forKey: "ZorofinPreferences-v1.full")
        await #expect(throws: SettingsError.storageFull) { try await store.save(value, server: server, viewerID: "two") }
        #expect(try await restored.load(server: server, viewerID: "one") == value)
    }
    @Test func failedWritesAndInvalidValuesAreReported() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to:root);defer { try? FileManager.default.removeItem(at:root) }
        let store=NativePreferenceStore(root:root),server=try ServerAddress("https://media.example")
        await #expect(throws:(any Error).self) { try await store.save(.init(),server:server,viewerID:"one") }
        var invalid=NativePreferences();invalid.bitrate = -1
        await #expect(throws:SettingsError.invalidInput) { try await store.save(invalid,server:server,viewerID:"one") }
    }
    private func movie() throws -> MediaItem {
        try Wire.decoder().decode(MediaItem.self,from:Data(#"{"Id":"film","Name":"Film","Type":"Movie","MediaSources":[{"MediaStreams":[{"Index":0,"Type":"Audio","Language":"eng","IsDefault":true},{"Index":1,"Type":"Audio","Language":"spa"},{"Index":2,"Type":"Subtitle","Language":"spa"},{"Index":3,"Type":"Subtitle","Language":"eng","IsForced":true}]}]}"#.utf8))
    }
    @Test func explicitTitleTrackChoicesOverrideAccountDefaults() throws {
        let settings=ViewerSettings(name:"Viewer",configuration:["SubtitleMode":.string("Always"),"SubtitleLanguagePreference":.string("spa")])
        let options=settings.playbackOptions(.init(audioIndex:1,subtitleIndex:-1),item:try movie())
        #expect(options.audioIndex == 1 && options.subtitleIndex == -1)
    }
    @Test func automaticSubtitlesHonorOffForcedAndPreferredLanguage() throws {
        let item=try movie()
        let off=ViewerSettings(name:"Viewer",configuration:["SubtitleMode":.string("None")])
        #expect(off.playbackOptions(.init(subtitleIndex:-2),item:item).subtitleIndex == -1)
        let forced=ViewerSettings(name:"Viewer",configuration:["SubtitleMode":.string("OnlyForced")])
        #expect(forced.playbackOptions(.init(subtitleIndex:-2),item:item).subtitleIndex == 3)
        let always=ViewerSettings(name:"Viewer",configuration:["SubtitleMode":.string("Always"),"SubtitleLanguagePreference":.string("es")])
        #expect(always.playbackOptions(.init(subtitleIndex:-2),item:item).subtitleIndex == 2)
    }
    @Test func smartUsesAudioLanguageAndKeepsForcedTranslations() throws {
        let same=ViewerSettings(name:"Viewer",configuration:["SubtitleMode":.string("Smart"),"SubtitleLanguagePreference":.string("en")])
        #expect(same.playbackOptions(.init(subtitleIndex:-2),item:try movie()).subtitleIndex == 3)
        let foreign=ViewerSettings(name:"Viewer",configuration:["SubtitleMode":.string("Smart"),"SubtitleLanguagePreference":.string("es")])
        #expect(foreign.playbackOptions(.init(subtitleIndex:-2),item:try movie()).subtitleIndex == 2)
    }
    @Test func preferredAudioAppliesOnlyWhenDefaultAudioIsNotRequested() throws {
        var settings=ViewerSettings(name:"Viewer",configuration:["AudioLanguagePreference":.string("es"),"PlayDefaultAudioTrack":.bool(false)])
        #expect(settings.playbackOptions(.init(),item:try movie()).audioIndex == 1)
        settings.configuration["PlayDefaultAudioTrack"] = .bool(true)
        #expect(settings.playbackOptions(.init(),item:try movie()).audioIndex == nil)
    }
    @Test func serverSelectionsHonorRememberedAudioAndSubtitleOff() throws {
        var item = try movie()
        item.mediaSources?[0].defaultAudioStreamIndex = 1
        item.mediaSources?[0].defaultSubtitleStreamIndex = -1
        let settings = ViewerSettings(name: "Viewer", configuration: ["SubtitleMode": .string("Always"), "SubtitleLanguagePreference": .string("eng")])
        let options = settings.playbackOptions(.init(subtitleIndex: -2), item: item)
        #expect(options.audioIndex == 1 && options.subtitleIndex == -1)
        item.mediaSources?[0].defaultAudioStreamIndex = 0
        #expect(settings.playbackOptions(.init(subtitleIndex: -2), item: item).audioIndex == nil)
    }
    @Test func freshPlaybackMetadataBypassesBrowsingCache() async throws {
        let transport = SettingsTransport([(200, #"{"Id":"film","Name":"Film","Type":"Movie"}"#),
            (200, #"{"Id":"film","Name":"Updated","Type":"Movie"}"#)])
        let base = try settingsClient(transport)
        let client = JellyfinClient(server: base.server, identity: base.identity, session: base.session, transport: transport,
            responseCache: LibraryResponseCache(server: base.server, viewerID: "viewer", root: nil))
        #expect(try await client.item("film").name == "Film")
        #expect(try await client.item("film").name == "Film")
        #expect(try await client.item("film", fresh: true).name == "Updated")
        #expect(await transport.requests.count == 2)
    }
    @Test func nextEpisodeRequiresAnAdjacentItemInTheSameSeries() async throws {
        var current=MediaItem(id:"episode1",name:"Episode",type:"Episode");current.seriesId="series"
        var next=MediaItem(id:"episode2",name:"Episode 2",type:"Episode");next.seriesId="series"
        let body=String(decoding:try Wire.encoder().encode(ItemPage(items:[current,next])),as:UTF8.self)
        let transport=SettingsTransport([(200,body)])
        #expect(try await settingsClient(transport).followingEpisode(current)?.id == "episode2")
        let request=await transport.requests[0]
        #expect(request.httpMethod == "GET" && request.url?.path == "/base/Shows/series/Episodes")
        let query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
        #expect(query.contains(.init(name:"startItemId",value:"episode1")))
        #expect(query.contains(.init(name:"limit",value:"2")))
        next.seriesId="another-series"
        let wrong=String(decoding:try Wire.encoder().encode(ItemPage(items:[current,next])),as:UTF8.self)
        #expect(try await settingsClient(SettingsTransport([(200,wrong)])).followingEpisode(current) == nil)
    }
}


@Suite("Additional native preferences") struct AdditionalNativePreferenceTests {
    @Test func olderPreferencesKeepTheirValuesAndUseSystemSubtitleAppearance() throws {
        var existing = NativePreferences(); existing.bitrate = 8_000_000; existing.showRatings = true
        let encoded = try JSONEncoder().encode(existing)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["subtitleAppearance", "showQualityBadges", "hideAvailableRequests", "homeScreenPreviews"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(NativePreferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.bitrate == 8_000_000 && decoded.showRatings)
        #expect(decoded.subtitleAppearance == nil && decoded.showQualityBadges != false && decoded.hideAvailableRequests != true)
    }
    @Test func newPreferencesSurviveRelaunchWithoutCrossingAccountBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerAddress("https://media.example/base")
        var preferences = NativePreferences()
        preferences.subtitleAppearance = .init()
        preferences.subtitleAppearance?.size = 150
        preferences.subtitleAppearance?.color = .yellow
        preferences.showQualityBadges = false; preferences.hideAvailableRequests = true
        try await NativePreferenceStore(root: root).save(preferences, server: server, viewerID: "one")
        #expect(try await NativePreferenceStore(root: root).load(server: server, viewerID: "one") == preferences)
        #expect(try await NativePreferenceStore(root: root).load(server: server, viewerID: "two") == .init())
        preferences.subtitleAppearance?.backgroundOpacity = .nan
        await #expect(throws: SettingsError.invalidInput) { try await NativePreferenceStore(root: root).save(preferences, server: server, viewerID: "one") }
    }
}
