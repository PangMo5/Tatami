import CoreGraphics
import Testing
@testable import TatamiKit

struct WindowTilerClientTests {
  @Test
  func `one capability result derives movable and resizable discoveries`() {
    let fixedSize = WindowKey(pid: 1, windowID: 10, bundleId: "app.fixed")
    let flexible = WindowKey(pid: 2, windowID: 20, bundleId: "app.flexible")
    let capabilities = WindowCapabilityDiscovery(
      movableKeys: [fixedSize, flexible],
      resizableKeys: [flexible],
      unreachable: ["app.busy"],
      retained: [30],
    )

    let movable = capabilities.discovery(requireResizable: false)
    let resizable = capabilities.discovery(requireResizable: true)

    #expect(movable.keys == [fixedSize, flexible])
    #expect(resizable.keys == [flexible])
    #expect(movable.unreachable == resizable.unreachable)
    #expect(movable.retained == resizable.retained)
  }

  @Test
  func `frame writes use the smallest safe AX mutation`() {
    let current = CGRect(x: 8, y: 41, width: 800, height: 600)

    #expect(
      WindowTilerClient.frameWritePlan(current: current, target: current) == .none
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 8, y: 41, width: 600, height: 600),
      ) == .resizeOnly
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 400, y: 41, width: 800, height: 600),
      ) == .moveOnly
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 400, y: 41, width: 600, height: 600),
        crossesDisplays: false,
      ) == .moveAndResizeOnce
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 400, y: 41, width: 600, height: 600),
        crossesDisplays: true,
      ) == .moveAndResizeTwice
    )
    #expect(
      WindowTilerClient.frameWritePlan(current: nil, target: current)
        == .moveAndResizeTwice
    )
  }

  @Test
  func `fresh window server frames skip only current targets`() {
    let current = WindowKey(pid: 1, windowID: 10, bundleId: "app.current")
    let withinTolerance = WindowKey(pid: 2, windowID: 20, bundleId: "app.tolerance")
    let drifted = WindowKey(pid: 3, windowID: 30, bundleId: "app.drifted")
    let offscreen = WindowKey(pid: 4, windowID: 40, bundleId: "app.offscreen")
    let target = CGRect(x: 8, y: 41, width: 800, height: 600)

    let pending = WindowTilerClient.framesNeedingApply(
      targets: [
        current: target,
        withinTolerance: target,
        drifted: target,
        offscreen: target,
      ],
      visibleFrames: [
        current.windowID: target,
        withinTolerance.windowID: target.offsetBy(dx: 0.5, dy: -0.5),
        drifted.windowID: target.offsetBy(dx: 3, dy: 0),
      ],
    )

    #expect(pending == [drifted: target, offscreen: target])

    let forced = WindowTilerClient.framesNeedingApply(
      targets: [
        current: target,
        withinTolerance: target,
        drifted: target,
        offscreen: target,
      ],
      visibleFrames: [
        current.windowID: target,
        withinTolerance.windowID: target,
        drifted.windowID: target,
        offscreen.windowID: target,
      ],
      forceAllFrames: true,
    )

    #expect(Set(forced.keys) == [current, withinTolerance, drifted, offscreen])
  }
}
