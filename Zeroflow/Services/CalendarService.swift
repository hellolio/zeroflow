import Foundation
import EventKit

/// EventKit 封装：日历权限 + 按时间区间查日程（灵动岛面板用）。
/// 不做日历筛选，使用系统日历 App 中已勾选的全部日历（calendars: nil）。
final class CalendarService {
    static let shared = CalendarService()

    private let store = EKEventStore()

    /// 当前日历访问权限
    var status: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// 请求完整访问权限（macOS 14+，首次调用弹系统授权窗）
    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, error in
            if let error {
                ZSLog("CalendarService: request access failed: \(error)")
            }
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// 取 [start, end) 区间内的日程。未授权时返回空数组。
    /// EKEventStore 查询可能较慢，调用方放到后台线程。
    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
    }
}
