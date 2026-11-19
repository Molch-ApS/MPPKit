// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import MPPModel
import MPP14
import MPPKit

/// Microsoft Project XML: what goes out comes back.
final class MSPDITests: XCTestCase {
    private func assertRoundTrip(_ p: Project, file: StaticString = #filePath, line: UInt = #line) throws {
        let back = try MSPDI.project(from: MSPDI.data(p))
        XCTAssertEqual(back.title, p.title, file: file, line: line)
        XCTAssertEqual(back.tasks.count, p.tasks.count, file: file, line: line)
        for (a, b) in zip(p.tasks, back.tasks) {
            XCTAssertEqual(a.uid, b.uid, file: file, line: line)
            XCTAssertEqual(a.name, b.name, file: file, line: line)
            XCTAssertEqual(a.outlineLevel, b.outlineLevel, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.parentUID, b.parentUID, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.start, b.start, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.finish, b.finish, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.durationDays, b.durationDays, accuracy: 0.001, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.durationUnits, b.durationUnits, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.constraint, b.constraint, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.constraintDate, b.constraintDate, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.deadline, b.deadline, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.percentComplete, b.percentComplete, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.manual, b.manual, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.text, b.text, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.baselines[0]?.start, b.baselines[0]?.start, "\(a.name)", file: file, line: line)
        }
        XCTAssertEqual(Set(p.relations.map { "\($0.predUID)>\($0.succUID) \($0.type) \($0.lagUnits)" }),
                       Set(back.relations.map { "\($0.predUID)>\($0.succUID) \($0.type) \($0.lagUnits)" }), file: file, line: line)
        for (a, b) in zip(p.relations.sorted { ($0.predUID, $0.succUID) < ($1.predUID, $1.succUID) },
                          back.relations.sorted { ($0.predUID, $0.succUID) < ($1.predUID, $1.succUID) }) {
            XCTAssertEqual(a.lagDays, b.lagDays, accuracy: 0.001, file: file, line: line)
        }
        XCTAssertEqual(back.resources.map(\.name), p.resources.map(\.name), file: file, line: line)
        XCTAssertEqual(back.assignments.count, p.assignments.count, file: file, line: line)
        XCTAssertEqual(back.calendar?.exceptions.count, p.calendar?.exceptions.count, file: file, line: line)
        XCTAssertEqual(back.fieldAliases, p.fieldAliases, file: file, line: line)
        // Same plan, same schedule.
        var x = p, y = back
        try Scheduler.schedule(&x)
        try Scheduler.schedule(&y)
        XCTAssertEqual(x.tasks.map(\.finish), y.tasks.map(\.finish), file: file, line: line)
    }

    func testSampleProjectRoundTrips() throws {
        var p = SampleProject.make()
        p.fieldAliases["text1"] = "Area"
        p.tasks[3].text[1] = "Level 3"
        p.tasks[4].deadline = MPPTime.date(2026, 3, 20, 17)
        p.relations[0].lagUnits = "ed"
        p.calendar?.exceptions.append(CalendarException(start: MPPTime.date(2026, 5, 2), name: "Saturday", working: [480...720]))
        try assertRoundTrip(p)
    }

    func testProjectSavedFileRoundTrips() throws {
        let p = try MPP14File(bytes: Fixture.bytes()).readProject()
        try assertRoundTrip(p)
    }

    func testDurationText() {
        XCTAssertEqual(MSPDI.duration(minutes: 480), "PT8H0M0S")
        XCTAssertEqual(MSPDI.parseDuration("PT8H30M0S"), 510)
        XCTAssertEqual(MSPDI.parseDuration("-PT2H0M0S"), -120)
        XCTAssertEqual(MSPDI.textFieldID(1), 188_743_731)
        XCTAssertEqual(MSPDI.textNumber(188_744_016), 30)
    }

    // MARK: Plain Swift instead of Foundation's formatters and XMLParser (WebAssembly build)

    /// Dates: the same text as DateFormatter wrote, and read back, from 1601 to 2400.
    func testDatesMatchDateFormatter() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var rng = SystemRandomNumberGenerator()
        var samples: [TimeInterval] = [0, -1, 86_399, 86_400, -86_400, 951_782_400, 4_107_542_399, -11_644_473_600, 13_569_465_599]
        for _ in 0..<5000 { samples.append(TimeInterval(Int.random(in: -11_644_473_600...13_569_465_599, using: &rng))) }
        samples += [1.5, -0.25, 59.999]
        for t in samples {
            let d = Date(timeIntervalSince1970: t)
            XCTAssertEqual(MSPDI.date(d), f.string(from: d), "\(t)")
            let whole = Date(timeIntervalSince1970: t.rounded(.down))
            XCTAssertEqual(MSPDI.parseDate(MSPDI.date(d)), whole, "\(t)")
        }
        XCTAssertEqual(MSPDI.parseDate("2026-11-19T08:30:00.000+01:00"), f.date(from: "2026-11-19T08:30:00"))
        for bad in ["", "2026-11-19", "2026-13-01T00:00:00", "2026-02-30T00:00:00", "2025-02-29T00:00:00",
                    "2026-11-19T24:00:00", "2026-11-19 08:00:00", "2026-1x-19T08:00:00"] {
            XCTAssertNil(MSPDI.parseDate(bad), bad)
        }
        XCTAssertNotNil(MSPDI.parseDate("2024-02-29T00:00:00"))
        XCTAssertNotNil(MSPDI.parseDate("2000-02-29T23:59:59"))
        XCTAssertNil(MSPDI.parseDate("1900-02-29T00:00:00"))
    }

    func testNumbersMatchStringFormat() {
        var values: [Double] = [0, -0.0, 1, 0.5, 0.125, 0.375, 1.005, 2.675, 99.999, 100, 1234.5678, -0.004, -0.5, 0.004, 1e9]
        for _ in 0..<20000 { values.append(Double.random(in: -1000...1000)); values.append(Double(Int.random(in: 0...100_000)) / 1000) }
        for v in values { XCTAssertEqual(MSPDI.fixed2(v), String(format: "%.2f", v), "\(v)") }
        for m in [0, 5, 59, 60, 480, 1020, 1439, 1440] {
            XCTAssertEqual(MSPDI.clock(m), String(format: "%02d:%02d", m / 60, m % 60))
        }
    }

    private func tree(_ xml: String) throws -> XMLTree { try XMLTree.parse(Data(xml.utf8)) }

    func testXMLReader() throws {
        let t = try tree("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <!DOCTYPE Project [ <!ENTITY x "never"> ]>
        <!-- Project wrote this -->
        <Project xmlns="http://schemas.microsoft.com/project" a='1' b="x > y">
          <Name>A &amp; B &lt;1&gt; &quot;q&quot; &apos;s&apos; &#233;&#x1F600;</Name>
          <Empty/><Spaced  />
          <Note><![CDATA[<raw> & stuff]]></Note>
          <Lines>one\r\ntwo\rthree</Lines>
          <?pi inside?>
          <!-- a comment -->
          <Tasks><Task><UID>1</UID><Name>Trailing space </Name></Task><Task><UID>2</UID></Task></Tasks>
          <ns:Prefixed>p</ns:Prefixed>
        </Project>
        """)
        XCTAssertEqual(t.name, "Project")
        XCTAssertEqual(t["Name"], "A & B <1> \"q\" 's' é😀")
        XCTAssertEqual(t["Empty"], "")
        XCTAssertNotNil(t.child("Spaced"))
        XCTAssertEqual(t["Note"], "<raw> & stuff")
        XCTAssertEqual(t["Lines"], "one\ntwo\nthree")
        XCTAssertEqual(t.child("Tasks")?.children("Task").count, 2)
        XCTAssertEqual(t.child("Tasks")?.children("Task").first?["Name"], "Trailing space ")
        XCTAssertEqual(t["ns:Prefixed"], "p")
    }

    func testXMLReaderEncodings() throws {
        let xml = "<?xml version=\"1.0\"?><Project><Name>Ærø ✓</Name></Project>"
        XCTAssertEqual(try XMLTree.parse(Data([0xEF, 0xBB, 0xBF] + Array(xml.utf8)))["Name"], "Ærø ✓")
        var le: [UInt8] = [0xFF, 0xFE], be: [UInt8] = [0xFE, 0xFF]
        for u in xml.utf16 { le += [UInt8(u & 0xFF), UInt8(u >> 8)]; be += [UInt8(u >> 8), UInt8(u & 0xFF)] }
        XCTAssertEqual(try XMLTree.parse(Data(le))["Name"], "Ærø ✓")
        XCTAssertEqual(try XMLTree.parse(Data(be))["Name"], "Ærø ✓")
    }

    func testXMLReaderRefusesWhatIsNotWellFormed() {
        for bad in ["", "   ", "plain text", "<a>", "<a></b>", "<a><b></a></b>", "<a>&unknown;</a>", "<a>& </a>",
                    "<a>&#0;</a>", "<a>&#xD800;</a>", "<a></a><b></b>", "<a></a>trailing", "<a b></a>", "<a b=c></a>",
                    "<a b=\"1\"c=\"2\"></a>", "<a b=\"<\"></a>", "<a><![CDATA[x</a>", "<a><!-- x</a>", "<1a></1a>", "<a"] {
            XCTAssertThrowsError(try tree(bad), bad)
        }
        XCTAssertThrowsError(try MSPDI.project(from: Data("<NotAProject/>".utf8)))
    }

    func testXMLReaderTakesDeepNestingWithoutRecursion() throws {
        let n = 100_000
        let t = try tree(String(repeating: "<a>", count: n) + "x" + String(repeating: "</a>", count: n))
        XCTAssertEqual(t.name, "a")
    }

    #if canImport(FoundationXML) || os(macOS) || os(iOS)
    /// The same tree as Foundation's XMLParser built, for every file we write and a Project-style one.
    func testXMLReaderMatchesXMLParser() throws {
        var p = SampleProject.make()
        p.title = "Quotes \" & <angles> 'and' ✓"
        p.tasks[1].name = "Line\r\nbreak & tab\tend "
        var files = [MSPDI.data(p), MSPDI.data(try MPP14File(bytes: Fixture.bytes()).readProject())]
        files.append(Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r
        <Project xmlns="http://schemas.microsoft.com/project">\r
        \t<Name>Röad &amp; Bridge</Name>\r
        \t<Tasks><Task><UID>0</UID><Name>Röad</Name><Notes>a&#13;&#10;b</Notes></Task><Task/></Tasks>\r
        </Project>\r
        """.utf8))
        for data in files {
            XCTAssertEqual(describe(try XMLTree.parse(data)), describe(try Oracle.parse(data)))
        }
    }

    /// Every Microsoft Project XML file in MPXJ's corpus (Tools/ci/fetch-corpus.sh,
    /// Project 2002-2019): the same tree as XMLParser's, and it opens as a plan.
    func testProjectSavedXMLMatchesXMLParser() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("Corpus")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw XCTSkip("no XML corpus in \(dir.path) — run Tools/ci/fetch-corpus.sh") }
        var plans = 0
        for url in files {
            let data = try Data(contentsOf: url)
            guard let oracle = try? Oracle.parse(data) else { continue }   // not XML to Foundation either
            assertSame(describe(try XMLTree.parse(data)), describe(oracle), url.lastPathComponent)
            if oracle.name == "Project" {
                XCTAssertNoThrow(try MSPDI.project(from: data), url.lastPathComponent)
                plans += 1
            }
        }
        XCTAssertGreaterThan(plans, 100)
        // Project writes notes as CDATA, which the reader once dropped.
        if let sample = files.first(where: { $0.lastPathComponent == "sample.xml" }) {
            let p = try MSPDI.project(from: Data(contentsOf: sample))
            XCTAssert(p.tasks.contains { $0.notes == "Test Task Notes" }, "the task's notes from CDATA")
        }
    }

    /// Equal, or where they part.
    private func assertSame(_ a: String, _ b: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard a != b else { return }
        let x = Array(a), y = Array(b)
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        let from = max(0, i - 80)
        XCTFail("\(what) parts at \(i): ours …\(String(x[from..<min(x.count, i + 80)]))… XMLParser's …\(String(y[from..<min(y.count, i + 80)]))…", file: file, line: line)
    }

    private func describe(_ t: XMLTree) -> String {
        "<\(t.name)>\(t.text.debugDescription)[" + t.kids.map(describe).joined(separator: ",") + "]"
    }
    private func describe(_ t: Oracle) -> String {
        "<\(t.name)>\(t.text.debugDescription)[" + t.kids.map(describe).joined(separator: ",") + "]"
    }

    /// The tree the reader built before, from XMLParser, with CDATA kept.
    private final class Oracle: NSObject, XMLParserDelegate {
        var name = "", text = "", kids: [Oracle] = []
        private var stack: [Oracle] = [], root: Oracle?
        static func parse(_ data: Data) throws -> Oracle {
            let b = Oracle(), parser = XMLParser(data: data)
            parser.delegate = b
            guard parser.parse(), let r = b.root else { throw parser.parserError ?? MSPDI.Failure.notMSPDI }
            return r
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let n = Oracle(); n.name = name
            stack.last?.kids.append(n); if root == nil { root = n }; stack.append(n)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        // The old reader dropped CDATA, and with it the notes Project writes there; the new one keeps it.
        func parser(_ parser: XMLParser, foundCDATA data: Data) { stack.last?.text += String(decoding: data, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
    }
    #endif
}
