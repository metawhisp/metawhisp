import XCTest
@testable import MetaWhisp

/// These strings are sent to the user's real browser, so each one is pinned
/// exactly and every inserted value is escaped before it can reach AppleScript.
final class DiaScriptTests: XCTestCase {
    func testQuotingEscapesBackslashAndDoubleQuote() {
        XCTAssertEqual(DiaScript.quoted(#"a"b\c"#), #""a\"b\\c""#)
    }

    func testQuotingEscapesLineBreaksAndTabs() {
        XCTAssertEqual(DiaScript.quoted("a\nb\rc\td"), "\"a\\nb\\rc\\td\"")
    }

    func testOnlyWebURLsCanBeOpened() {
        XCTAssertTrue(DiaScript.isOpenable(URL(string: "https://example.com")!))
        XCTAssertTrue(DiaScript.isOpenable(URL(string: "http://example.com/a?b=c")!))

        XCTAssertFalse(DiaScript.isOpenable(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "file:///etc/hosts")!))
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "data:text/html,x")!))
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "mailto:someone@example.com")!))
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "https:///no-host")!))
    }

    func testOpeningANonWebURLProducesNoScript() {
        XCTAssertNil(DiaScript.openTab(url: URL(string: "javascript:alert(1)")!))
    }

    func testOpenTabScript() {
        XCTAssertEqual(
            DiaScript.openTab(url: URL(string: "https://example.com")!),
            """
            tell application id "company.thebrowser.dia"
                with timeout of 5 seconds
                    set w to front window
                    set t to make new tab at end of tabs of w with properties {URL:"https://example.com"}
                    try
                        return (id of w) & linefeed & (id of t)
                    on error errorMessage number errorNumber
                        close t
                        error errorMessage number errorNumber
                    end try
                end timeout
            end tell
            """
        )
    }

    /// The same scripts drive Chrome, which shares Dia's scripting terms:
    /// only the addressed app changes (the probe on Chrome, 2026-09-25).
    func testTheScriptsCanAddressChrome() throws {
        let chrome = "tell application id \"com.google.Chrome\""
        let open = try XCTUnwrap(DiaScript.openTab(url: URL(string: "https://example.com")!,
                                                   bundleID: DiaScript.chromeBundleID))
        XCTAssertTrue(open.hasPrefix(chrome))
        XCTAssertTrue(DiaScript.execute(windowID: "1", tabID: "2", javascript: "document.title",
                                        bundleID: DiaScript.chromeBundleID).hasPrefix(chrome))
        XCTAssertTrue(DiaScript.frontActiveTab().hasPrefix("tell application id \"company.thebrowser.dia\""),
                      "Dia stays the default")
    }

    func testWebSchemesAreMatchedWhateverTheirCase() {
        XCTAssertTrue(DiaScript.isOpenable(URL(string: "HTTPS://Example.com")!))
        XCTAssertTrue(DiaScript.isOpenable(URL(string: "hTTp://example.com")!))
    }

    func testRelativeAndBlobURLsCannotBeOpened() {
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "/relative/path")!))
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "blob:https://example.com/0a1b")!))
    }

    /// These URLs have a real host, so only the scheme check can refuse them.
    func testANonWebSchemeIsRefusedEvenWithAHost() {
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "ftp://example.com/file")!))
        XCTAssertFalse(DiaScript.isOpenable(URL(string: "wss://example.com/socket")!))
    }

    // MARK: - ITER-076 I-09: no private address (owner decision D7)

    private func refused(_ addresses: [String], file: StaticString = #filePath, line: UInt = #line) {
        for address in addresses {
            XCTAssertFalse(DiaScript.isOpenable(URL(string: address)!), address, file: file, line: line)
        }
    }

    private func opened(_ addresses: [String], file: StaticString = #filePath, line: UInt = #line) {
        for address in addresses {
            XCTAssertTrue(DiaScript.isOpenable(URL(string: address)!), address, file: file, line: line)
        }
    }

    func testLocalNamesAreNeverOpened() {
        refused(["http://localhost:8080", "http://LOCALHOST/", "http://localhost./", "http://a.localhost/",
                 "http://router.local", "http://Router.Local./x"])
    }

    /// Names reserved for private networks, which public DNS never answers:
    /// a home network's (RFC 8375) and any private network's (ICANN, 2024)
    /// (ITER-076 I-09 review, NET-3).
    func testNamesReservedForPrivateNetworksAreNeverOpened() {
        refused(["http://router.home.arpa/", "http://home.arpa/", "http://ROUTER.Home.Arpa./x", "http://nas.internal/",
                 "https://a.b.internal:8443/"])
        opened(["https://nothome.arpa/", "https://internal.example.com/", "https://example.xinternal/"])
    }

    /// Names ICANN resolved never to give to anyone (2018) — `.home`, `.corp`
    /// and `.mail` — which only the user's own resolver answers: a home
    /// router's name among them. Refused as `.internal` is, on a label
    /// boundary (Claude review c7 of I-09, #9).
    func testNamesNeverDelegatedAreNeverOpened() {
        refused(["http://bthomehub.home/", "http://home/", "http://Router.HOME./x", "http://intranet.corp/",
                 "https://a.b.corp:8443/", "http://mx.mail/", "http://NAS.Mail./"])
        opened(["https://home.example.com/", "https://example.homes/", "https://corp.example.com/",
                "https://example.mycorp/", "https://mail.example.com/", "https://example.email/"])
    }

    func testAHostWithNoDotIsNeverOpened() {
        refused(["http://intranet/", "http://intranet./", "https://nas:5001/"])
        opened(["https://example.com./", "https://site-1.test/"])
    }

    func testLoopbackInEveryEncodingIsNeverOpened() {
        refused(["http://127.0.0.1/", "http://127.9.8.7/", "http://127.1/", "http://0x7f000001/", "http://2130706433/",
                 "http://0177.0.0.1/", "http://0x7f.1/", "http://127.0.0.1./", "http://user:pw@127.0.0.1/",
                 "http://%31%32%37.0.0.1/", "http://\u{FF11}\u{FF12}\u{FF17}.\u{FF10}.\u{FF10}.\u{FF11}/",
                 "http://0x7f.0.0.0x1/", "http://0X7F.0x0.0x0.0x1/"])
    }

    func testPrivateNetworksAreNeverOpened() {
        refused(["http://10.0.0.5", "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1",
                 "http://0xc0a80101/"])
        opened(["http://172.15.0.1/", "http://172.32.0.1/", "http://192.169.1.1/"])
    }

    func testLinkLocalIsNeverOpened() {
        refused(["http://169.254.169.254/", "http://169.254.0.1/", "http://[fe80::1]/", "http://[febf::1]/"])
        opened(["http://169.253.0.1/", "http://[fec0::1]/"])
    }

    func testCarrierGradeNATIsNeverOpened() {
        refused(["http://100.64.0.1", "http://100.127.255.255/"])
        opened(["http://100.63.255.255/", "http://100.128.0.1/"])
    }

    func testTheUnspecifiedAddressIsNeverOpened() {
        refused(["http://0.0.0.0/", "http://0/", "http://[::]/"])
    }

    func testIPv6LoopbackAndUniqueLocalAreNeverOpened() {
        refused(["http://[::1]/", "http://[0:0:0:0:0:0:0:1]/", "http://[fc00::1]/", "http://[fd12:3456::1]/"])
    }

    func testIPv4MappedIPv6IsNeverOpenedForAPrivateAddress() {
        refused(["http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/", "http://[::ffff:192.168.1.1]/",
                 "http://[::ffff:c0a8:101]/", "http://[::ffff:a00:5]/"])
        opened(["http://[::ffff:8.8.8.8]/"])
    }

    /// A host that ends in a number is an IPv4 address, as a browser parses
    /// one: one that is no valid address is no page at all.
    func testANumericHostThatIsNoAddressIsNeverOpened() {
        refused(["http://1.2.3.4.5/", "http://09.1.2.3/", "http://256.1.1.1/", "http://0x1g.0.0.1/"])
    }

    func testPublicAddressesStillOpen() {
        opened(["http://8.8.8.8/", "https://1.1.1.1/dns", "http://134744072/", "http://[2001:4860:4860::8888]/",
                "https://www.example.com/a?b=c", "http://0x8.0x8.0x8.0x8/", "http://010.010.010.010/"])
    }

    func testAPlanKeepsNoPrivateAddress() throws {
        let plan = try XCTUnwrap(AgentPlan(
            goal: "Look", subgoals: [.init(description: "Look", terms: ["look"])],
            searches: ["http://192.168.1.1", "http://router.local", "http://localhost:8080", "http://[::1]/",
                       "http://10.0.0.5", "http://100.64.0.1", "http://169.254.169.254/", "http://intranet/",
                       "http://0x7f000001/", "https://search.test/?q=look"].map { URL(string: $0)! },
            columns: ["Name"], sheetTitle: "Look", rowsWanted: 1, emptyCell: "n/a"))
        XCTAssertEqual(plan.searches.map(\.absoluteString), ["https://search.test/?q=look"])
        XCTAssertNil(AgentPlan(goal: "Look", subgoals: [.init(description: "Look", terms: ["look"])],
                               searches: [URL(string: "http://192.168.1.1")!], columns: ["Name"], sheetTitle: "Look",
                               rowsWanted: 1, emptyCell: "n/a"), "a plan with only private addresses is no plan")
    }

    func testAnEmptyScriptIsStillAQuotedLiteral() {
        XCTAssertTrue(
            DiaScript.execute(windowID: "W1", tabID: "T1", javascript: "")
                .contains(#"javascript """#)
        )
    }

    func testEveryBuilderEscapesHostileIDs() {
        let windowID = #"W"1\"#
        let tabID = #"T"1"#
        let expectedTab = #"tab id "T\"1""#
        let expectedWindow = #"window id "W\"1\\""#

        XCTAssertTrue(
            DiaScript.isLoading(windowID: windowID, tabID: tabID)
                .contains(expectedTab)
        )
        XCTAssertTrue(
            DiaScript.isLoading(windowID: windowID, tabID: tabID)
                .contains(expectedWindow)
        )
        XCTAssertTrue(
            DiaScript.execute(windowID: windowID, tabID: tabID, javascript: "1")
                .contains(expectedTab)
        )
        XCTAssertTrue(
            DiaScript.execute(windowID: windowID, tabID: tabID, javascript: "1")
                .contains(expectedWindow)
        )
        XCTAssertTrue(
            DiaScript.closeTab(windowID: windowID, tabID: tabID)
                .contains(expectedTab)
        )
        XCTAssertTrue(
            DiaScript.closeTab(windowID: windowID, tabID: tabID)
                .contains(expectedWindow)
        )
    }

    func testWhitespaceOnlyIDsAreRejected() {
        XCTAssertNil(DiaScript.parseIDs(" \n "))
    }

    func testACarriageReturnIsNotPartOfAnID() {
        let ids = DiaScript.parseIDs("W1\r\nT1")
        XCTAssertEqual(ids?.windowID, "W1")
        XCTAssertEqual(ids?.tabID, "T1")
    }

    /// Snapshot equality proves the text; this proves AppleScript reads it
    /// back as the same string — no browser involved.
    func testQuotedTextSurvivesARealAppleScriptRoundTrip() {
        for input in [#"a"b\c"#, "line1\nline2", "tab\there", "", "ünïcødé ✓", #"\"#] {
            var error: NSDictionary?
            let result = NSAppleScript(source: "return " + DiaScript.quoted(input))!
                .executeAndReturnError(&error)

            XCTAssertNil(error)
            XCTAssertEqual(result.stringValue, input)
        }
    }

    func testFrontActiveTabScript() {
        XCTAssertEqual(
            DiaScript.frontActiveTab(),
            """
            tell application id "company.thebrowser.dia"
                with timeout of 5 seconds
                    set w to front window
                    return (id of w) & linefeed & (id of active tab of w)
                end timeout
            end tell
            """
        )
    }

    func testIsLoadingScript() {
        XCTAssertEqual(
            DiaScript.isLoading(windowID: "W1", tabID: "T1"),
            """
            tell application id "company.thebrowser.dia"
                with timeout of 5 seconds
                    return (loading of tab id "T1" of window id "W1") as text
                end timeout
            end tell
            """
        )
    }

    func testExecuteScript() {
        XCTAssertEqual(
            DiaScript.execute(windowID: "W1", tabID: "T1", javascript: "document.title"),
            """
            tell application id "company.thebrowser.dia"
                with timeout of 5 seconds
                    return execute tab id "T1" of window id "W1" javascript "document.title"
                end timeout
            end tell
            """
        )
    }

    func testExecuteEscapesTheJavaScript() {
        XCTAssertTrue(
            DiaScript.execute(
                windowID: "W1",
                tabID: "T1",
                javascript: #"document.querySelector("a").href"#
            ).contains(#"javascript "document.querySelector(\"a\").href""#)
        )
    }

    func testExecuteEscapesTheIDs() {
        XCTAssertTrue(
            DiaScript.execute(
                windowID: "W1",
                tabID: #"T"1"#,
                javascript: "1"
            ).contains(##"tab id "T\"1""##)
        )
    }

    func testCloseTabScript() {
        XCTAssertEqual(
            DiaScript.closeTab(windowID: "W1", tabID: "T1"),
            """
            tell application id "company.thebrowser.dia"
                with timeout of 5 seconds
                    close tab id "T1" of window id "W1"
                end timeout
            end tell
            """
        )
    }

    func testTheTimeoutIsWrittenIntoTheScript() {
        XCTAssertTrue(
            DiaScript.execute(windowID: "W1", tabID: "T1", javascript: "1", timeoutSeconds: 12)
                .contains("with timeout of 12 seconds")
        )
    }

    func testParsingTheWindowAndTabIDs() {
        let plain = DiaScript.parseIDs("W1\nT1")
        XCTAssertEqual(plain?.windowID, "W1")
        XCTAssertEqual(plain?.tabID, "T1")

        let padded = DiaScript.parseIDs(" W1 \n T1 ")
        XCTAssertEqual(padded?.windowID, "W1")
        XCTAssertEqual(padded?.tabID, "T1")

        XCTAssertNil(DiaScript.parseIDs("W1"))
        XCTAssertNil(DiaScript.parseIDs("W1\n"))
        XCTAssertNil(DiaScript.parseIDs("W1\nT1\nX"))
        XCTAssertNil(DiaScript.parseIDs(""))
    }
}
