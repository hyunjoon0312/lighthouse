import Foundation

/// 사이드바·오른쪽 패널 너비. 끌어서 정한 너비를 기억하되, 가운데 사진 영역이 위쪽 막대가 들어가는 너비보다 좁아지지 않게 한다.
enum PanelLayout {
    static let sidebarDefault = 224.0
    static let sidebarRange = 180.0...360.0
    /// 보정 패널은 기본 너비에 맞춰 짜여 있어 그보다 좁히지 않는다.
    static let inspectorDefault = 300.0
    static let inspectorRange = 300.0...520.0
    /// 가장 작은 창(1100pt)에 기본 너비 두 패널을 두었을 때 남는 가운데 너비. 위쪽 막대가 이 너비에 맞춰져 있다.
    static let minimumCenter = 574.0

    /// 숨긴 패널은 0. 창이 좁아 모자라면 오른쪽 패널부터 기본 너비까지 줄이고, 그래도 모자라면 사이드바를 줄인다.
    static func widths(total: Double, sidebar: Double, inspector: Double,
                       showsSidebar: Bool, showsInspector: Bool) -> (sidebar: Double, inspector: Double) {
        var side = showsSidebar ? clamp(sidebar, sidebarRange) : 0
        var right = showsInspector ? clamp(inspector, inspectorRange) : 0
        let dividers = Double((showsSidebar ? 1 : 0) + (showsInspector ? 1 : 0))
        var excess = side + right + dividers + minimumCenter - total
        if excess > 0, showsInspector {
            let cut = min(excess, right - inspectorRange.lowerBound)
            right -= cut; excess -= cut
        }
        if excess > 0, showsSidebar {
            side -= min(excess, side - sidebarRange.lowerBound)
        }
        return (side, right)
    }

    /// 끄는 동안의 너비. 다른 패널(`other`)은 그대로 두고, 가운데가 최소 너비에 닿으면 더 넓어지지 않는다.
    static func dragged(_ proposed: Double, range: ClosedRange<Double>, total: Double, other: Double, dividers: Double) -> Double {
        let room = total - other - dividers - minimumCenter
        return clamp(min(proposed, room), range)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
