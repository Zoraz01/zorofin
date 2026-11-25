sub Test_AudioChannelAndHdrNegotiation()
    device = {
        GetDisplayProperties: function() as object
            return { hdr10: true, hdr10Plus: true, dolbyVision: false }
        end function
        GetVideoMode: function() as string
            return "2160p60"
        end function
        CanDecodeVideo: function(req) as object
            return { result: req.codec = "hevc" }
        end function
        CanDecodeAudio: function(req) as object
            if req.codec = "aac" then return { result: req.chcnt = invalid }
            return { result: req.codec = "eac3" }
        end function
    }
    profile = ZDeviceProfileFor(device, 0).profile
    hls = profile.TranscodingProfiles[0]
    AssertEqual(hls.AudioCodec, "aac,eac3", "AC3 requires a separate positive probe")
    AssertEqual(hls.MaxAudioChannels, "8", "EAC3 7.1 may copy")
    for each rule in profile.CodecProfiles
        if rule.codec = "aac" then AssertEqual(rule.Conditions[0].Value, "2", "AAC keeps its own ceiling")
        if rule.codec = "eac3" then AssertEqual(rule.Conditions[0].Value, "8", "EAC3 channel probe")
        if rule.codec = "hevc" then AssertEqual(rule.Conditions[1].Value, "SDR|HDR10|HDR10Plus", "screen ranges")
    end for
end sub
