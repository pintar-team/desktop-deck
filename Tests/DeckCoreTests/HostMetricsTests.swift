import XCTest
@testable import DeckCore

final class HostMetricsTests: XCTestCase {
    func testCPUWarmupDeltaAndCounterReset() throws {
        var accumulator=HostMetricsAccumulator()
        func sample(_ total: UInt64,_ idle: UInt64) throws -> HostMetrics {
            accumulator.record(try XCTUnwrap(RawHostMetrics.parse("CPU_COUNTER\t\(total)\t\(idle)")),platform:.linux)
        }
        XCTAssertNil(try sample(1000,600).cpuPercent)
        XCTAssertEqual(try XCTUnwrap(sample(1200,650).cpuPercent),75,accuracy:0.001)
        XCTAssertNil(try sample(1200,650).cpuPercent)
        XCTAssertNil(try sample(100,50).cpuPercent,"A reboot must establish a new baseline")
        XCTAssertEqual(try XCTUnwrap(sample(200,100).cpuPercent),50,accuracy:0.001)
        XCTAssertNil(try sample(300,90).cpuPercent,"Linux iowait can decrease; do not fabricate CPU usage")
        XCTAssertNil(try sample(301,100).cpuPercent,"Idle delta cannot exceed total delta")
    }
    func testDiskUnitsAndDirectCPUWithoutCounters() throws {
        let raw=try XCTUnwrap(RawHostMetrics.parse("login banner\nCPU_PERCENT\t12.5\nDISK_KIB\t1000\t250\t/\n"))
        var accumulator=HostMetricsAccumulator()
        let metrics=accumulator.record(raw,platform:.macOS)
        XCTAssertEqual(metrics.cpuPercent,12.5)
        let disk=try XCTUnwrap(metrics.disk)
        XCTAssertEqual(disk.totalBytes,1_024_000);XCTAssertEqual(disk.availableBytes,256_000)
        XCTAssertEqual(disk.usedPercent,75,accuracy:0.001)
        let windows=try XCTUnwrap(RawHostMetrics.parse("DECK_WINDOWS\r\nCPU_PERCENT\t9\r\nDISK_BYTES\t1000\t300\tC:\\\r\n"))
        XCTAssertEqual(windows.disk?.path,"C:\\");XCTAssertEqual(windows.disk?.availableBytes,300)
    }
    func testInvalidMetricsAndPartialAvailability() throws {
        for line in ["CPU_PERCENT\tnan","CPU_PERCENT\tinf","CPU_PERCENT\t101","CPU_PERCENT\t-1","CPU_COUNTER\t4\t5","DISK_KIB\t18446744073709551615\t0\t/","DISK_BYTES\t0\t0\t/","DISK_BYTES\t10\t11\t/"] {
            XCTAssertNil(RawHostMetrics.parse(line),line)
        }
        let raw=try XCTUnwrap(RawHostMetrics.parse("CPU_PERCENT\tunknown\nDISK_BYTES\t1000\t1000\t/"))
        XCTAssertNil(raw.cpuPercent);XCTAssertEqual(raw.disk?.usedPercent,0)
    }
    func testOSDetectionDoesNotTreatAnSSHBannerAsAPlatform() {
        XCTAssertEqual(HostPlatform.detect(uname:"banner\nLinux\n"),.linux)
        XCTAssertEqual(HostPlatform.detect(uname:"Darwin"),.macOS)
        XCTAssertEqual(HostPlatform.detect(uname:"FreeBSD"),.bsd)
        XCTAssertEqual(HostPlatform.detect(uname:"MINGW64_NT"),.unix)
        XCTAssertNil(HostPlatform.detect(uname:"Access denied"))
        XCTAssertNil(HostPlatform.detect(uname:""))
    }
}
