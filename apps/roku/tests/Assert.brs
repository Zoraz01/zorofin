' Minimal assertions for tests/run.js. Failures print "FAIL <test>: <message>".

sub AssertEqual(actual as dynamic, expected as dynamic, message as string)
    m.checks = m.checks + 1
    if FormatJson(actual) <> FormatJson(expected) then
        m.failures = m.failures + 1
        print "FAIL " + m.current + ": " + message + " (got " + FormatJson(actual) + ", want " + FormatJson(expected) + ")"
    end if
end sub

sub AssertTrue(value as boolean, message as string)
    m.checks = m.checks + 1
    if not value then
        m.failures = m.failures + 1
        print "FAIL " + m.current + ": " + message
    end if
end sub
