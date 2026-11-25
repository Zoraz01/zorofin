function ReadReply(stamp = "2026-11-09T20:00:00.000Z" as string) as object
    return { id: "Tq8x2m4k", updatedAt: stamp, message: "Sample support reply", localSeen: false }
end function

function ReadAccount(initialized = true as boolean) as object
    return ZParseNotificationReads({ initialized: initialized, requests: [], replies: [] })
end function

sub Test_NotificationReads_ContractAndIdentity()
    key = "Tq8x2m4k|2026-11-09T20:00:00.000Z"
    s = ZParseNotificationReads({ initialized: true, requests: [41, 57], replies: [key] })
    AssertTrue(s.requests["41"], "request id")
    AssertTrue(s.replies[key], "exact reply id/time")
    AssertEqual(ZNotificationReplyIdentity(ReadReply()), key, "no timestamp normalization")
    AssertTrue(ZParseNotificationReads({ initialized: true, requests: ["41"], replies: [] }) = invalid, "string ids rejected")
    AssertTrue(ZParseNotificationReads({ initialized: true, requests: [-1], replies: [] }) = invalid, "negative ids rejected")
    AssertTrue(ZParseNotificationReads({ initialized: true, requests: [1.5], replies: [] }) = invalid, "fraction rejected")
    AssertTrue(ZParseNotificationReads({ initialized: "true", requests: [], replies: [] }) = invalid, "boolean contract")
    AssertTrue(ZParseNotificationReads({ initialized: false, requests: [], replies: ["Tq8x2m4k|bad"] }) = invalid, "bad timestamp")
end sub

sub Test_NotificationReads_MergesTwoDevices()
    notices = [{ id: 41 }]
    replies = [ReadReply()]
    localB = { initialized: true, requests: {} }
    account = ReadAccount()
    AssertEqual(ZNotificationRows(notices, replies, localB, account).unread, 2, "unread on device B")
    ' Device A's read POST becomes the next account GET on B.
    account = ZParseNotificationReads({ initialized: true, requests: [41], replies: [ZNotificationReplyIdentity(replies[0])] })
    AssertEqual(ZNotificationRows(notices, replies, localB, account).unread, 0, "both read on B after refresh")
    replies = [ReadReply("2026-11-09T20:02:00.000Z")]
    AssertEqual(ZNotificationRows(notices, replies, localB, account).unread, 1, "new reply on same ticket unread")
    replies[0].localSeen = true
    AssertEqual(ZNotificationRows(notices, replies, localB, invalid).unread, 1, "offline fallback still honors local reply read; request remains locally unread")
end sub

sub Test_NotificationReads_FirstSnapshotAndFreshDevice()
    notices = [{ id: 41 }, { id: 57 }]
    local = { initialized: false, requests: {} }
    plan = ZNotificationPlan(notices, [], local, ReadAccount(false), true)
    AssertEqual(plan.requests, [41, 57], "first account snapshot posted as history")
    AssertTrue(plan.initialize, "initialize server only after request check")
    AssertEqual(plan.mark, [41, 57], "history also retained locally")
    plan = ZNotificationPlan(notices, [], local, ReadAccount(), true)
    AssertEqual(plan.mark.count(), 0, "initialized account skips fresh-device history rule")
    AssertEqual(plan.requests.count(), 0, "does not acknowledge real unread notices")
    AssertEqual(ZNotificationRows(notices, [], local, ReadAccount()).unread, 2, "fresh device sees account's real unread list")
    plan = ZNotificationPlan([], [], local, ReadAccount(false), false)
    AssertTrue(not plan.initialize, "failed/incomplete request check cannot initialize")
    AssertTrue(not plan.localInitialized, "nor initialize local history")
    plan = ZNotificationPlan([], [], local, ReadAccount(false), true)
    AssertTrue(plan.initialize, "successful empty snapshot initializes")
end sub

sub Test_NotificationReads_MigrationAndOfflineRetry()
    notices = [{ id: 41 }, { id: 57 }]
    local = { initialized: true, requests: { "41": true, "999": true } }
    reply = ReadReply()
    reply.localSeen = true
    plan = ZNotificationPlan(notices, [reply], local, ReadAccount(), true)
    AssertEqual(plan.requests, [41], "migrate only still-ready local ids")
    AssertEqual(plan.replies[0].updatedAt, reply.updatedAt, "migrate exact seen reply")
    AssertTrue(not plan.initialize, "migration does not initialize again")
    plan = ZNotificationPlan(notices, [reply], local, invalid, true)
    AssertEqual(plan.requests.count() + plan.replies.count(), 0, "GET error uses local only for refresh")
    AssertEqual(ZNotificationRows(notices, [reply], local, invalid).unread, 1, "merged local fallback")
    plan = ZNotificationPlan(notices, [reply], local, ReadAccount(), true)
    AssertEqual(plan.requests, [41], "failed write retried while missing remotely")
    AssertEqual(plan.replies.count(), 1, "seen reply retried without per-ticket endpoint")
    plan = ZNotificationPlan(notices, [], local, ReadAccount(), false)
    AssertEqual(plan.requests.count(), 0, "failed request refresh cannot migrate stale ready list")
end sub

sub Test_NotificationReads_BatchesAndMonotonicity()
    requests = []
    for i = 1 to 1001
        requests.push(i)
    end for
    batches = ZNotificationBatches(requests, [ReadReply()], true)
    AssertEqual(batches.count(), 3, "bounded writes")
    AssertEqual(batches[0].requests.count(), 500, "first batch")
    AssertEqual(batches[1].requests.count(), 500, "second batch")
    AssertEqual(batches[2].requests.count() + batches[2].replies.count(), 2, "last combined count")
    AssertTrue(not batches[0].initialize and not batches[1].initialize and batches[2].initialize, "initialize last")
    AssertEqual(ZNotificationBatches([], [], false).count(), 0, "no empty writes")
    AssertEqual(ZNotificationBatches([], [], true).count(), 1, "empty initialization still posted")
    newer = ZParseNotificationReads({ initialized: true, requests: [41, 57], replies: [] })
    old = ZParseNotificationReads({ initialized: false, requests: [41], replies: [] })
    merged = ZMergeNotificationReads(newer, old)
    AssertTrue(merged.initialized and merged.requests["57"], "late response cannot undo newer read")
end sub

sub Test_NotificationReads_ScopeIsolation()
    a = { server: "https://demo.example/", userId: "one", token: "sample-a" }
    b = LiveWith(a, { userId: "two" })
    c = LiveWith(a, { server: "https://other.example/" })
    d = LiveWith(a, { token: "sample-b" })
    AssertTrue(ZNotificationScope(a) <> ZNotificationScope(b), "account switch")
    AssertTrue(ZNotificationScope(a) <> ZNotificationScope(c), "server switch")
    AssertTrue(ZNotificationScope(a) <> ZNotificationScope(d), "old session callback")
    AssertEqual(ZNotificationScope({}), "", "signed out")
end sub

sub Test_NotificationReads_RequestQualityAndSeasons()
    activity = { id: 41, requestStatus: 2, type: "movie", tmdbId: 100, title: "Sample film" }
    detail = { id: 100, mediaInfo: { status: 5, status4k: 2, requests: [{ id: 41, status: 2, is4k: false }] } }
    AssertEqual(ZReadyRequest(activity, detail).id, 41, "approved standard request fulfilled")
    detail.mediaInfo.requests[0].is4k = true
    AssertTrue(ZReadyRequest(activity, detail) = invalid, "standard copy cannot fulfill 4K request")
    detail.mediaInfo.status4k = 5
    AssertEqual(ZReadyRequest(activity, detail).message, "Your 4K request is available.", "ready 4K")
    activity.type = "tv"
    detail.mediaInfo.requests[0].seasons = [{ seasonNumber: 2 }]
    detail.mediaInfo.seasons = [{ seasonNumber: 1, status4k: 5 }, { seasonNumber: 2, status4k: 2 }]
    AssertTrue(ZReadyRequest(activity, detail) = invalid, "another season cannot fulfill request")
    detail.mediaInfo.status4k = 4
    detail.mediaInfo.seasons[1].status4k = 5
    AssertTrue(ZReadyRequest(activity, detail) <> invalid, "requested season ready in partially available show")
    detail.mediaInfo.requests[0].id = 42
    AssertTrue(ZReadyRequest(activity, detail) = invalid, "exact receipt required")
end sub
