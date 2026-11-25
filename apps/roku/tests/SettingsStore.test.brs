sub Test_Settings_TogglesPersist()
    p = ZSettings()
    p.showChapters = true
    p["sendPlaybackReports"] = false
    p.skipBack = 15
    p.reduceMotion = true
    ZSaveSettings(p)
    q = ZSettings()
    AssertTrue(q.showChapters = true, "show chapters saved (dot assignment)")
    AssertTrue(q.sendPlaybackReports = false, "report opt-out saved (bracket assignment)")
    AssertEqual(q.skipBack, 15, "skip back saved")
    AssertTrue(q.reduceMotion = true, "reduce motion saved")
    ZRegWrite("settings", { showChapters: true })
    AssertTrue(ZSettings().showChapters = true, "older camel-case files still load")
    ZSaveSettings({})
    AssertTrue(ZSettings().showChapters = false, "reset to defaults")
end sub
