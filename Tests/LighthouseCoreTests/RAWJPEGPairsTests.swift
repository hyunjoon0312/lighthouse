import Foundation
import XCTest
@testable import LighthouseCore

final class RAWJPEGPairsTests: XCTestCase {
    private func photo(_ path: String) -> PhotoAsset { PhotoAsset(url: URL(fileURLWithPath: path)) }

    func testFindsCameraJPEGBesideRAWOnly() {
        let raw = photo("/card/P1000001.RW2")
        let jpeg = photo("/card/p1000001.JPG")
        let heif = photo("/card/P1000001.HIF.heic")
        let lone = photo("/card/P1000002.JPG")
        let elsewhere = photo("/other/P1000001.JPG")
        let png = photo("/card/P1000001.png")
        let copy = jpeg.virtualCopy(among: [jpeg])
        let all = [raw, jpeg, heif, lone, elsewhere, png, copy]
        let companions = RAWJPEGPairs.companions(in: all)
        XCTAssertEqual(companions, [jpeg.id: [raw.id]], "같은 폴더·같은 이름의 JPEG만 짝이고, PNG·다른 폴더·사본은 제외")
        XCTAssertTrue(RAWJPEGPairs.companions(in: [jpeg, lone]).isEmpty, "RAW가 없으면 숨기지 않는다")
    }
}
