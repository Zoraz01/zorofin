' The type scale keeps Roku to a few glyph atlases (see ZTypeStyle).

sub Test_TypeScale_SevenStylesAtMost()
    seen = {}
    for each weight in ["regular", "semibold", "bold"]
        for size = 12 to 120
            s = ZTypeStyle(size, weight)
            seen[s.weight + Str(s.size)] = true
        end for
    end for
    AssertTrue(seen.count() <= 7, "at most seven styles, got" + Str(seen.count()))
end sub

sub Test_TypeScale_Mapping()
    AssertEqual(ZTypeStyle(17), { size: 18, weight: "regular" }, "card caption")
    AssertEqual(ZTypeStyle(22, "semibold"), { size: 22, weight: "semibold" }, "card title")
    AssertEqual(ZTypeStyle(30, "bold"), { size: 30, weight: "semibold" }, "row label")
    AssertEqual(ZTypeStyle(56, "bold"), { size: 48, weight: "bold" }, "page title")
    AssertEqual(ZTypeStyle(28), { size: 27, weight: "regular" }, "status text")
end sub
