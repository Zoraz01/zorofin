' Server address rules shared with the Apple and Flutter apps.

sub Test_Server_BareLocalHostTriesHttpsThenHttp()
    r = ZServerCandidates("192.168.1.20")
    AssertTrue(r.ok, "accepted")
    AssertEqual(r.candidates, ["https://192.168.1.20/", "http://192.168.1.20:8096/", "http://192.168.1.20/"], "candidates")
end sub

sub Test_Server_RemoteHttpIsRefused()
    r = ZServerCandidates("http://media.example.com")
    AssertTrue(not r.ok, "plain HTTP outside the home network is refused")
    r = ZServerCandidates("media.example.com")
    AssertEqual(r.candidates, ["https://media.example.com/"], "bare remote host is HTTPS only")
end sub

sub Test_Server_RejectsCredentialsAndDotSegments()
    AssertTrue(not ZParseServer("https://user:pw@media.example.com").ok, "credentials")
    AssertTrue(not ZParseServer("https://media.example.com/../x").ok, "dot segments")
    AssertTrue(not ZParseServer("https://media.example.com:70000").ok, "bad port")
end sub

sub Test_Server_EndpointEscapesAndValidates()
    AssertEqual(ZEndpoint("https://m.example/", ["Items", "abc"], { b: "x y", a: "1" }), "https://m.example/Items/abc?a=1&b=x%20y", "path and sorted query")
    AssertEqual(ZEndpoint("https://m.example/", ["Items", "../x"]), "", "unsafe path component")
end sub

sub Test_Server_AuthHeader()
    h = ZAuthHeader("Living Room", "dev1", "1.0.1", "tok")
    AssertEqual(h, "MediaBrowser Client=""Zorofin"", Device=""Living Room"", DeviceId=""dev1"", Version=""1.0.1"", Token=""tok""", "header")
end sub
