import Foundation
import Testing
@testable import QuotaBarApp

@Suite("Dashboard layout")
struct DashboardLayoutTests {
    @Test("account viewport reserves header footer and notices on all supported heights")
    func reservesControls() {
        for height: CGFloat in [360, 420, 580] {
            for hasNotice in [false, true] {
                let viewport = DashboardLayout.listHeight(panelHeight: height, hasNotice: hasNotice)
                let notice: CGFloat = hasNotice ? DashboardLayout.updateNoticeHeight + DashboardLayout.stackSpacing : 0
                let controls = DashboardLayout.topInset + DashboardLayout.headerHeight + DashboardLayout.headerListSpacing + DashboardLayout.listFooterSpacing + DashboardLayout.footerHeight + notice
                #expect(viewport > 0)
                #expect(viewport + controls <= height)
                #expect(viewport <= DashboardLayout.maxAccountListHeight)
            }
        }
    }

    @Test("notice consumes only the scroll viewport")
    func noticeDoesNotMoveFooter() {
        let normal = DashboardLayout.listHeight(panelHeight: 580, hasNotice: false)
        let withNotice = DashboardLayout.listHeight(panelHeight: 580, hasNotice: true)
        #expect(normal - withNotice == DashboardLayout.updateNoticeHeight + DashboardLayout.stackSpacing)
    }
}
