import Cocoa
import UserNotifications

// =====================================================================
//  CloudMeter  --  GCP Billing Menu Bar Tracker
//  Pure AppKit  |  Zero Dependencies  |  Single File
// =====================================================================

// MARK: ─── Layout Constants ─────────────────────────────────────────

let POP_W:       CGFloat = 520
let POP_MAX_H:   CGFloat = 700
let HDR_H:       CGFloat = 92
let FILTER_H:    CGFloat = 28
let CHART_H:     CGFloat = 194
let ROW_H:       CGFloat = 40
let FTR_H:       CGFloat = 40
let PAD:         CGFloat = 12
let DOT_SZ:      CGFloat = 8
let COST_BAR_W:  CGFloat = 56
let COST_COL_W:  CGFloat = 72
let CHART_L:     CGFloat = 44   // y-axis label area
let CHART_B:     CGFloat = 34   // x-axis label area
let CHART_T:     CGFloat = 10   // top padding
let CHART_R:     CGFloat = 14   // right padding

let SVC_COLORS: [NSColor] = [.systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemPink]
let OTHER_CLR: NSColor = NSColor.systemGray.withAlphaComponent(0.5)

// Settings options — single source of truth
let REFRESH_LABELS = ["2x Daily", "Hourly", "Manual"]
let REFRESH_VALUES = [0, 60, -1]  // 0 = smart 2x/day, 60 = hourly, -1 = manual only
let DISPLAY_LABELS = ["Yesterday", "MTD", "Burn Rate"]
let DISPLAY_VALUES = ["yesterday", "mtd", "burn"]
let ALERT_LABELS   = ["70%", "80%", "90%", "100%"]
let ALERT_VALUES   = [70, 80, 90, 100]

// MARK: ─── Models ───────────────────────────────────────────────────

struct SvcCost {
    let name: String; let cost: Double; let credits: Double
    var sub: Double { cost + credits }
}

struct BillDay {
    let date: String; let services: [SvcCost]
    var total: Double { services.reduce(0) { $0 + $1.sub } }
    var totalCredits: Double { services.reduce(0) { $0 + $1.credits } }
}

struct MonthSum {
    let month: String; let cost: Double; let credits: Double
    var sub: Double { cost + credits }
}

// MARK: ─── Config ───────────────────────────────────────────────────

struct Cfg: Codable {
    var projectId: String
    var datasetId: String
    var tableId: String
    var refreshMin: Int
    var displayMode: String   // "today","mtd","burn"
    var monthlyBudget: Double
    var alertPct: Int
    var enableAlerts: Bool
    var enableDaily: Bool

    static let path: String = {
        let d = NSHomeDirectory() + "/.config/cloudmeter"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d + "/config.json"
    }()

    static let `default` = Cfg(
        projectId: "your-gcp-project-id",
        datasetId: "gcp_billing_export",
        tableId: "gcp_billing_export_v1_XXXXXX_XXXXXX_XXXXXX",
        refreshMin: 0, displayMode: "yesterday", monthlyBudget: 0,
        alertPct: 80, enableAlerts: false, enableDaily: false
    )

    static func load() -> Cfg {
        guard let d = FileManager.default.contents(atPath: path),
              let c = try? JSONDecoder().decode(Cfg.self, from: d) else {
            let c = Cfg.default; c.save(); return c
        }
        return c
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: URL(fileURLWithPath: Cfg.path)) }
    }
}

// MARK: ─── OAuth2 ───────────────────────────────────────────────────

class Auth {
    static let shared = Auth()
    private var token: String?
    private var expiry: Date?
    private let adcPath = NSHomeDirectory() + "/.config/gcloud/application_default_credentials.json"
    private let queue = DispatchQueue(label: "auth.token")

    func getToken(_ done: @escaping (String?) -> Void) {
        queue.async { [self] in
            if let t = token, let e = expiry, Date() < e.addingTimeInterval(-60) {
                done(t); return
            }
            refresh(done)
        }
    }

    private func refresh(_ done: @escaping (String?) -> Void) {
        // called inside queue.async already
        guard let data = FileManager.default.contents(atPath: adcPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = json["client_id"] as? String,
              let csec = json["client_secret"] as? String,
              let rtok = json["refresh_token"] as? String else {
            print("[Auth] Cannot read ADC at \(adcPath)")
            done(nil); return
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "client_id=\(urlEncode(cid))",
            "client_secret=\(urlEncode(csec))",
            "refresh_token=\(urlEncode(rtok))"
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { [weak self] d, _, err in
            self?.queue.async {
                guard let d = d, err == nil,
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let tok = j["access_token"] as? String,
                      let exp = j["expires_in"] as? Int else {
                    print("[Auth] Token refresh failed: \(err?.localizedDescription ?? "parse error")")
                    done(nil); return
                }
                self?.token = tok
                self?.expiry = Date().addingTimeInterval(Double(exp))
                done(tok)
            }
        }.resume()
    }

    private func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D") ?? s
    }
}

// MARK: ─── BigQuery ─────────────────────────────────────────────────

class BQ {
    static func query(_ sql: String, project: String, token: String,
                      done: @escaping ([[String]]?) -> Void) {
        let url = URL(string: "https://bigquery.googleapis.com/bigquery/v2/projects/\(project)/queries")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["query": sql, "useLegacySql": false,
                                   "timeoutMs": 30000, "maxResults": 2000]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { d, _, err in
            guard let d = d, err == nil,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                print("[BQ] Request failed: \(err?.localizedDescription ?? "unknown")")
                done(nil); return
            }
            if let e = j["error"] as? [String: Any] {
                print("[BQ] Error: \(e["message"] ?? "")")
                done(nil); return
            }
            guard let rows = j["rows"] as? [[String: Any]] else { done([]); return }
            let parsed: [[String]] = rows.compactMap { row in
                guard let fields = row["f"] as? [[String: Any]] else { return nil }
                return fields.map { ($0["v"] as? String) ?? "" }
            }
            done(parsed)
        }.resume()
    }
}

// MARK: ─── Data Manager ─────────────────────────────────────────────

class DataMgr {
    var days: [BillDay] = []           // last 14 days (first 7 = comparison, last 7 = display)
    var displayDays: [BillDay] = []    // last 7 days only
    var compDays: [BillDay] = []       // previous 7 days
    var curMonth: MonthSum?
    var prevMonth: MonthSum?
    var lastUpdate: Date?
    var error: String?
    var budget: Double = 0
    var allProjects: [String] = []       // distinct project IDs
    var selectedProject: String? = nil   // nil = all projects
    // Per-project cost summaries: [projectId: (yesterday: Double, rolling7d: Double)]
    var projectCosts: [String: (yesterday: Double, rolling7d: Double)] = [:]

    // Cached after each refresh — avoids recomputing per-row
    private var _topServices: [(name: String, total: Double)] = []
    private var _top5Names: [String] = []

    var topServices: [(name: String, total: Double)] { _topServices }
    var top5Names: [String] { _top5Names }

    private func recomputeTopServices() {
        var totals: [String: Double] = [:]
        for d in displayDays { for s in d.services { totals[s.name, default: 0] += s.sub } }
        _topServices = totals.sorted { $0.value > $1.value }.map { (name: $0.key, total: $0.value) }
        _top5Names = Array(_topServices.prefix(5).map { $0.name })
    }

    func colorFor(_ name: String) -> NSColor {
        if let i = _top5Names.firstIndex(of: name), i < SVC_COLORS.count { return SVC_COLORS[i] }
        return OTHER_CLR
    }

    var mtd: Double { curMonth?.sub ?? 0 }
    var mtdCredits: Double { curMonth?.credits ?? 0 }
    var prevMonthTotal: Double { prevMonth?.sub ?? 0 }
    var prevMonthCost: Double { prevMonth?.cost ?? 0 }

    var dayOfMonth: Int { Calendar.current.component(.day, from: Date()) }
    var daysInMonth: Int { Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30 }
    var rolling7d: Double { displayDays.reduce(0) { $0 + $1.total } }
    var burnRate: Double { dayOfMonth > 0 ? mtd / Double(dayOfMonth) : 0 }
    var forecast: Double { dayOfMonth > 0 ? mtd / Double(dayOfMonth) * Double(daysInMonth) : 0 }
    var discountAmt: Double { abs(mtdCredits) }
    var discountPct: Double { prevMonthCost > 0 ? discountAmt / prevMonthCost * 100 : 0 }

    // Cached DateFormatter — DateFormatter is expensive to create
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func todayString() -> String { dateFmt.string(from: Date()) }

    static func yesterdayString() -> String {
        dateFmt.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
    }

    var todaySpend: Double {
        displayDays.first(where: { $0.date == DataMgr.todayString() })?.total ?? 0
    }

    var yesterdaySpend: Double {
        let yStr = DataMgr.yesterdayString()
        return displayDays.first(where: { $0.date == yStr })?.total ??
               days.first(where: { $0.date == yStr })?.total ?? 0
    }

    func menuValue(_ mode: String) -> Double {
        switch mode {
        case "mtd": return mtd
        case "burn": return burnRate
        default: return yesterdaySpend
        }
    }

    func menuLabel(_ mode: String) -> String {
        switch mode {
        case "mtd": return "MTD "
        case "burn": return ""
        default: return ""
        }
    }

    func menuSuffix(_ mode: String) -> String {
        mode == "burn" ? "/day" : ""
    }

    // SKU drill-down cache
    var skuCache: [String: [(sku: String, cost: Double, credits: Double)]] = [:]

    func fetchSKUs(service: String, forDate: String?, cfg: Cfg,
                   done: @escaping ([(sku: String, cost: Double, credits: Double)]?) -> Void) {
        let cacheKey = "\(service)|\(forDate ?? "7d")|\(selectedProject ?? "all")"
        if let cached = skuCache[cacheKey] { done(cached); return }

        let projFilter = selectedProject
        Auth.shared.getToken { token in
            guard let token = token else { done(nil); return }
            let tbl = "`\(cfg.projectId).\(cfg.datasetId).\(cfg.tableId)`"
            let dateFilter: String
            if let d = forDate {
                dateFilter = "AND DATE(usage_start_time) = '\(d)'"
            } else {
                dateFilter = "AND DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)"
            }
            let projF: String
            if let p = projFilter {
                projF = "AND project.id = '\(p.replacingOccurrences(of: "'", with: "\\'"))'"
            } else { projF = "" }
            let q = """
                SELECT sku.description AS sku,
                  ROUND(SUM(cost),4) AS cost,
                  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),4) AS credits
                FROM \(tbl)
                WHERE service.description = '\(service.replacingOccurrences(of: "'", with: "\\'"))'
                  \(dateFilter) \(projF)
                GROUP BY sku ORDER BY cost DESC
                """
            BQ.query(q, project: cfg.projectId, token: token) { [weak self] rows in
                guard let rows = rows else { DispatchQueue.main.async { done(nil) }; return }
                let skus = rows.compactMap { r -> (sku: String, cost: Double, credits: Double)? in
                    guard r.count >= 3 else { return nil }
                    return (r[0], Double(r[1]) ?? 0, Double(r[2]) ?? 0)
                }
                DispatchQueue.main.async {
                    self?.skuCache[cacheKey] = skus
                    done(skus)
                }
            }
        }
    }

    // Percent change for a service in 7-day view
    func pctChange7d(_ name: String) -> Double? {
        let cur = displayDays.reduce(0.0) { tot, d in
            tot + (d.services.first(where: { $0.name == name })?.sub ?? 0)
        }
        let prev = compDays.reduce(0.0) { tot, d in
            tot + (d.services.first(where: { $0.name == name })?.sub ?? 0)
        }
        guard prev > 0.01 else { return cur > 0.01 ? 999 : nil }
        return (cur - prev) / prev * 100
    }

    // Percent change for a service day-over-day — uses full `days` array
    // so first display day can compare against last comparison day
    func pctChangeDay(_ name: String, date: String) -> Double? {
        guard let dayIdx = days.firstIndex(where: { $0.date == date }), dayIdx > 0 else { return nil }
        let cur = days[dayIdx].services.first(where: { $0.name == name })?.sub ?? 0
        let prev = days[dayIdx - 1].services.first(where: { $0.name == name })?.sub ?? 0
        guard prev > 0.01 else { return cur > 0.01 ? 999 : nil }
        return (cur - prev) / prev * 100
    }

    func refresh(_ cfg: Cfg, done: @escaping (Bool) -> Void) {
        Auth.shared.getToken { [weak self] token in
            guard let token = token else {
                self?.error = "Auth failed"; done(false); return
            }
            let tbl = "`\(cfg.projectId).\(cfg.datasetId).\(cfg.tableId)`"
            let projFilter: String
            if let p = self?.selectedProject {
                projFilter = "AND project.id = '\(p.replacingOccurrences(of: "'", with: "\\'"))'"
            } else {
                projFilter = ""
            }
            let q1 = """
                SELECT service.description AS service, DATE(usage_start_time) AS date,
                  ROUND(SUM(cost),4) AS cost,
                  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),4) AS credits
                FROM \(tbl)
                WHERE DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 14 DAY)
                  \(projFilter)
                GROUP BY service, date ORDER BY date, cost DESC
                """
            let q2 = """
                SELECT FORMAT_DATE('%Y-%m', DATE(usage_start_time)) AS month,
                  ROUND(SUM(cost),2) AS cost,
                  ROUND(SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS credits
                FROM \(tbl)
                WHERE DATE(usage_start_time) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)
                  \(projFilter)
                GROUP BY month ORDER BY month
                """
            // Per-project daily totals (for dropdown labels)
            let q3 = """
                SELECT project.id, DATE(usage_start_time) AS date,
                  ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c),0)),2) AS subtotal
                FROM \(tbl)
                WHERE DATE(usage_start_time) >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
                  AND cost > 0
                GROUP BY project.id, date ORDER BY project.id, date
                """
            let grp = DispatchGroup()
            var r1: [[String]]?, r2: [[String]]?, r3: [[String]]?

            grp.enter()
            BQ.query(q1, project: cfg.projectId, token: token) { rows in r1 = rows; grp.leave() }
            grp.enter()
            BQ.query(q2, project: cfg.projectId, token: token) { rows in r2 = rows; grp.leave() }
            grp.enter()
            BQ.query(q3, project: cfg.projectId, token: token) { rows in r3 = rows; grp.leave() }

            grp.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                guard let rows1 = r1, let rows2 = r2 else {
                    self.error = "Query failed"; done(false); return
                }
                self.error = nil
                self.parseDailyData(rows1)
                self.parseMonthly(rows2)
                self.parseProjectCosts(r3 ?? [])
                self.recomputeTopServices()
                self.skuCache = [:]
                self.lastUpdate = Date()
                done(true)
            }
        }
    }

    private func parseDailyData(_ rows: [[String]]) {
        // rows: [service, date, cost, credits]
        var byDate: [String: [SvcCost]] = [:]
        for r in rows where r.count >= 4 {
            let svc = SvcCost(name: r[0], cost: Double(r[2]) ?? 0, credits: Double(r[3]) ?? 0)
            byDate[r[1], default: []].append(svc)
        }
        days = byDate.keys.sorted().map { BillDay(date: $0, services: byDate[$0]!) }
        let splitAt = max(0, days.count - 7)
        displayDays = Array(days.suffix(7))
        compDays = Array(days.prefix(splitAt))
    }

    private func parseMonthly(_ rows: [[String]]) {
        // rows: [month, cost, credits]
        let months = rows.compactMap { r -> MonthSum? in
            guard r.count >= 3 else { return nil }
            return MonthSum(month: r[0], cost: Double(r[1]) ?? 0, credits: Double(r[2]) ?? 0)
        }.sorted { $0.month < $1.month }

        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM"
        let curM = fmt.string(from: Date())
        curMonth = months.first(where: { $0.month == curM })
        prevMonth = months.first(where: { $0.month != curM })
    }

    private func parseProjectCosts(_ rows: [[String]]) {
        // rows: [project.id, date, subtotal]
        let yStr = DataMgr.yesterdayString()
        var perProject: [String: [String: Double]] = [:]  // [project: [date: cost]]
        for r in rows where r.count >= 3 {
            let proj = r[0]; let date = r[1]; let cost = Double(r[2]) ?? 0
            perProject[proj, default: [:]][date] = cost
        }
        allProjects = perProject.keys.sorted()
        projectCosts = [:]
        for (proj, dateCosts) in perProject {
            let yesterday = dateCosts[yStr] ?? 0
            let rolling7d = dateCosts.values.reduce(0, +)
            projectCosts[proj] = (yesterday: yesterday, rolling7d: rolling7d)
        }
    }
}

// MARK: ─── Helpers ──────────────────────────────────────────────────

class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var tag: Int { _tag }
    var _tag: Int = 0
}

private let _currFmt: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "AUD"
    f.currencySymbol = "$"; return f
}()

func fmtD(_ v: Double, cents: Bool = true) -> String {
    let showCents = cents && abs(v) < 1000
    _currFmt.minimumFractionDigits = showCents ? 2 : 0
    _currFmt.maximumFractionDigits = showCents ? 2 : 0
    return _currFmt.string(from: NSNumber(value: v)) ?? "$0"
}

func fmtPct(_ v: Double?) -> (String, NSColor)? {
    guard let v = v else { return nil }
    if abs(v) > 500 { return ("NEW", .secondaryLabelColor) }
    let arrow = v > 0 ? "\u{2191}" : "\u{2193}"  // up/down arrow
    let color: NSColor = v > 0 ? .systemRed : .systemGreen
    return ("\(arrow)\(Int(abs(v)))%", color)
}

func niceAxis(_ val: Double) -> (max: Double, step: Double) {
    if val <= 0 { return (100, 25) }
    let mag = pow(10, floor(log10(val)))
    let n = val / mag
    // Tighter scaling to match GCP console proportions
    let nice: Double
    if n <= 1.2 { nice = 1.5 }
    else if n <= 2.0 { nice = 2.5 }
    else if n <= 4.0 { nice = 5 }
    else if n <= 7.0 { nice = 8 }
    else { nice = 10 }
    let m = nice * mag
    let step = m / 4
    return (m, step)
}

func sf(_ name: String, _ sz: CGFloat = 12, _ wt: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: sz, weight: wt)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
}

func relativeTime(_ date: Date?) -> String {
    guard let d = date else { return "never" }
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

// MARK: ─── Chart View ───────────────────────────────────────────────

protocol ChartDelegate: AnyObject {
    func chartDidSelect(_ date: String)
}

class ChartView: NSView {
    weak var delegate: ChartDelegate?
    var days: [BillDay] = []
    var top5: [String] = []
    var colorFor: (String) -> NSColor = { _ in .systemGray }
    private var hoveredBar: Int = -1
    private var tooltip: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    private func barMetrics() -> (x: CGFloat, w: CGFloat, gap: CGFloat, count: Int) {
        let n = max(days.count, 1)
        let chartW = bounds.width - CHART_L - CHART_R
        let total = chartW / CGFloat(n)
        return (CHART_L, total * 0.65, total * 0.35, n)
    }

    private func barIndex(at pt: NSPoint) -> Int? {
        let m = barMetrics()
        for i in 0..<days.count {
            let bx = m.x + CGFloat(i) * (m.w + m.gap) + m.gap / 2
            if pt.x >= bx && pt.x <= bx + m.w && pt.y >= CHART_B && pt.y <= bounds.height - CHART_T {
                return i
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = barIndex(at: pt)
        if hoveredBar != (idx ?? -1) {
            hoveredBar = idx ?? -1
            setNeedsDisplay(bounds)
            showTooltip(idx)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBar = -1; setNeedsDisplay(bounds); hideTooltip()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let idx = barIndex(at: pt), idx < days.count {
            delegate?.chartDidSelect(days[idx].date)
        }
    }

    // Cached DateFormatters — expensive to create, called per-bar per-draw
    private static let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let shortFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd/MM"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d/M"; return f
    }()

    private func showTooltip(_ idx: Int?) {
        hideTooltip()
        guard let idx = idx, idx < days.count else { return }
        let day = days[idx]
        let m = barMetrics()
        let bx = m.x + CGFloat(idx) * (m.w + m.gap) + m.gap / 2

        let tip = FlippedView(frame: NSRect(x: bx - 20, y: bounds.height - CHART_T - 48,
                                             width: m.w + 40, height: 40))
        tip.wantsLayer = true
        tip.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        tip.layer?.cornerRadius = 6
        tip.layer?.borderWidth = 0.5
        tip.layer?.borderColor = NSColor.separatorColor.cgColor

        let lbl = NSTextField(labelWithString: "\(shortDate(day.date))\n\(fmtD(day.total))")
        lbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        lbl.alignment = .center
        lbl.maximumNumberOfLines = 2
        lbl.frame = NSRect(x: 2, y: 2, width: tip.frame.width - 4, height: 36)
        tip.addSubview(lbl)

        addSubview(tip)
        tooltip = tip
    }

    private func hideTooltip() { tooltip?.removeFromSuperview(); tooltip = nil }

    private func shortDate(_ s: String) -> String {
        guard let d = ChartView.isoFmt.date(from: s) else { return s }
        return ChartView.shortFmt.string(from: d)
    }

    private func dayLabel(_ s: String) -> (day: String, date: String) {
        guard let d = ChartView.isoFmt.date(from: s) else { return ("?", s) }
        return (ChartView.dayFmt.string(from: d), ChartView.dateFmt.string(from: d))
    }

    private func isToday(_ s: String) -> Bool {
        s == ChartView.isoFmt.string(from: Date())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        _ = ctx // silence warning

        let chartH = bounds.height - CHART_B - CHART_T
        let maxTotal = days.map(\.total).max() ?? 1
        let (axMax, axStep) = niceAxis(maxTotal)

        // Gridlines + y-axis labels
        let gridSteps = Int(axMax / axStep)
        for i in 0...gridSteps {
            let val = axStep * Double(i)
            let y = CHART_B + chartH * CGFloat(val / axMax)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: CHART_L, y: y))
            path.line(to: NSPoint(x: bounds.width - CHART_R, y: y))
            NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
            path.lineWidth = 0.5; path.stroke()

            let lbl = fmtD(val, cents: false)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let sz = (lbl as NSString).size(withAttributes: attrs)
            (lbl as NSString).draw(at: NSPoint(x: CHART_L - sz.width - 4, y: y - sz.height / 2),
                                   withAttributes: attrs)
        }

        // Bars
        let m = barMetrics()
        for (i, day) in days.enumerated() {
            let bx = m.x + CGFloat(i) * (m.w + m.gap) + m.gap / 2
            let today = isToday(day.date)

            // Sort segments: top5 order, then others
            var segments: [(name: String, val: Double)] = []
            var otherVal = 0.0
            for svc in day.services {
                if top5.contains(svc.name) { segments.append((svc.name, svc.sub)) }
                else { otherVal += svc.sub }
            }
            // ensure consistent order (same as top5)
            segments.sort { top5.firstIndex(of: $0.name) ?? 99 < top5.firstIndex(of: $1.name) ?? 99 }
            if otherVal > 0.001 { segments.append(("__other__", otherVal)) }

            // Draw stacked
            var yOff = CHART_B
            for seg in segments {
                let segH = chartH * CGFloat(seg.val / axMax)
                guard segH > 0.5 else { continue }
                let rect = NSRect(x: bx, y: yOff, width: m.w, height: segH)
                let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                let color = seg.name == "__other__" ? OTHER_CLR : colorFor(seg.name)

                if today {
                    color.withAlphaComponent(0.5).setFill()
                    path.fill()
                    color.withAlphaComponent(0.8).setStroke()
                    path.lineWidth = 1.5
                    let dashes: [CGFloat] = [3, 3]
                    path.setLineDash(dashes, count: 2, phase: 0)
                    path.stroke()
                } else {
                    color.setFill(); path.fill()
                }
                yOff += segH
            }

            // Hover highlight
            if i == hoveredBar {
                let hRect = NSRect(x: bx - 2, y: CHART_B, width: m.w + 4,
                                   height: chartH * CGFloat(day.total / axMax) + 2)
                let hPath = NSBezierPath(roundedRect: hRect, xRadius: 3, yRadius: 3)
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).setFill()
                hPath.fill()
            }

            // X-axis labels
            let (dayStr, dateStr) = dayLabel(day.date)
            let dayAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: today ? .bold : .medium),
                .foregroundColor: today ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let datAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let dsz = (dayStr as NSString).size(withAttributes: dayAttrs)
            (dayStr as NSString).draw(at: NSPoint(x: bx + m.w / 2 - dsz.width / 2, y: CHART_B - 28),
                                      withAttributes: dayAttrs)
            let dtsz = (dateStr as NSString).size(withAttributes: datAttrs)
            (dateStr as NSString).draw(at: NSPoint(x: bx + m.w / 2 - dtsz.width / 2, y: CHART_B - 15),
                                       withAttributes: datAttrs)

            // "partial" indicator for today
            if today {
                if let clk = sf("clock.fill", 7, .medium) {
                    let tint = NSColor.secondaryLabelColor
                    let img = NSImage(size: clk.size, flipped: false) { r in
                        tint.set(); clk.draw(in: r, from: r, operation: .sourceIn, fraction: 1.0)
                        return true
                    }
                    img.draw(in: NSRect(x: bx + m.w / 2 - 3.5, y: CHART_B - 13, width: 7, height: 7))
                }
            }
        }
    }
}

// MARK: ─── Main View Controller ─────────────────────────────────────

enum ViewMode { case overview; case dayDetail(String); case settings }

class MainVC: NSViewController, ChartDelegate {
    let data: DataMgr
    var cfg: Cfg
    var mode: ViewMode = .overview

    private var headerView: NSView!
    private var filterView: NSView!
    private var projectPopup: NSPopUpButton!
    private var chartView: ChartView!
    private var scrollView: NSScrollView!
    private var docView: FlippedView!
    private var footerView: NSView!
    private var settingsContainer: NSView?

    // Settings fields
    private var projField: NSTextField?
    private var dsField: NSTextField?
    private var tblField: NSTextField?
    private var refreshSeg: NSSegmentedControl?
    private var displaySeg: NSSegmentedControl?
    private var budgetField: NSTextField?
    private var alertCheck: NSButton?
    private var alertSeg: NSSegmentedControl?

    var expandedService: String?
    var currentDateFilter: String?  // nil = 7-day view, date string = day view

    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onConsole: (() -> Void)?
    var onConfigChanged: ((Cfg) -> Void)?
    var onExecReport: (() -> Void)?

    init(data: DataMgr, cfg: Cfg) {
        self.data = data; self.cfg = cfg; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = FlippedView(frame: NSRect(x: 0, y: 0, width: POP_W, height: 500))
        buildViews()
    }

    private func buildViews() {
        // Header
        headerView = NSView(frame: NSRect(x: 0, y: 0, width: POP_W, height: HDR_H))
        headerView.wantsLayer = true
        view.addSubview(headerView)

        // Project filter bar
        filterView = NSView(frame: NSRect(x: 0, y: HDR_H, width: POP_W, height: FILTER_H))
        filterView.wantsLayer = true
        let filterLbl = NSTextField(labelWithString: "Project")
        filterLbl.font = .systemFont(ofSize: 10); filterLbl.textColor = .secondaryLabelColor
        filterLbl.frame = NSRect(x: PAD, y: 4, width: 50, height: 16)
        filterView.addSubview(filterLbl)
        projectPopup = NSPopUpButton(frame: NSRect(x: PAD + 52, y: 2, width: POP_W - PAD * 2 - 52, height: 22))
        projectPopup.font = .systemFont(ofSize: 11)
        projectPopup.addItem(withTitle: "All Projects")
        projectPopup.target = self; projectPopup.action = #selector(projectChanged)
        filterView.addSubview(projectPopup)
        let fSep = NSView(frame: NSRect(x: 0, y: FILTER_H - 0.5, width: POP_W, height: 0.5))
        fSep.wantsLayer = true; fSep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        filterView.addSubview(fSep)
        view.addSubview(filterView)

        // Chart
        chartView = ChartView(frame: NSRect(x: 0, y: HDR_H + FILTER_H, width: POP_W, height: CHART_H))
        chartView.delegate = self
        view.addSubview(chartView)

        // Scroll
        let scrollY = HDR_H + FILTER_H + CHART_H
        let scrollH: CGFloat = 200
        scrollView = NSScrollView(frame: NSRect(x: 0, y: scrollY, width: POP_W, height: scrollH))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        docView = FlippedView(frame: NSRect(x: 0, y: 0, width: POP_W, height: 0))
        scrollView.documentView = docView
        view.addSubview(scrollView)

        // Footer
        footerView = NSView(frame: NSRect(x: 0, y: scrollY + scrollH, width: POP_W, height: FTR_H))
        footerView.wantsLayer = true
        view.addSubview(footerView)
        buildFooter()

        // Separator above footer
        let sep = NSView(frame: NSRect(x: 0, y: 0, width: POP_W, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        footerView.addSubview(sep)
    }

    private func buildFooter() {
        for v in footerView.subviews where v is NSButton { v.removeFromSuperview() }

        let refreshBtn = makeBtn("Refresh", #selector(refreshTap))
        refreshBtn.frame.origin = NSPoint(x: PAD, y: 8)
        footerView.addSubview(refreshBtn)

        let updLbl = NSTextField(labelWithString: "Updated \(relativeTime(data.lastUpdate))")
        updLbl.font = .systemFont(ofSize: 10)
        updLbl.textColor = .secondaryLabelColor
        updLbl.frame = NSRect(x: refreshBtn.frame.maxX + 8, y: 12, width: 120, height: 16)
        updLbl.tag = 999
        footerView.addSubview(updLbl)

        let quitBtn = makeBtn("Quit", #selector(quitTap))
        quitBtn.frame.origin = NSPoint(x: POP_W - quitBtn.frame.width - PAD, y: 8)
        footerView.addSubview(quitBtn)

        let gearBtn = makeBtn("", #selector(settingsTap))
        gearBtn.image = sf("gearshape", 12, .medium)
        gearBtn.frame = NSRect(x: quitBtn.frame.minX - 34, y: 8, width: 28, height: 24)
        footerView.addSubview(gearBtn)

        let consBtn = makeBtn("Console", #selector(consoleTap))
        consBtn.frame.origin = NSPoint(x: gearBtn.frame.minX - consBtn.frame.width - 6, y: 8)
        footerView.addSubview(consBtn)

        let execBtn = makeBtn("Exec Report", #selector(execReportTap))
        execBtn.contentTintColor = .systemPurple
        execBtn.frame.origin = NSPoint(x: consBtn.frame.minX - execBtn.frame.width - 6, y: 8)
        footerView.addSubview(execBtn)
    }

    private func makeBtn(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11, weight: .medium)
        b.sizeToFit(); b.frame.size.height = 24
        return b
    }

    @objc private func refreshTap() { onRefresh?() }
    @objc private func quitTap() { onQuit?() }
    @objc private func consoleTap() { onConsole?() }
    @objc private func settingsTap() { showSettings() }
    @objc private func execReportTap() { onExecReport?() }

    @objc private func projectChanged() {
        let idx = projectPopup.indexOfSelectedItem
        if idx <= 0 {
            data.selectedProject = nil
        } else {
            // item.title holds the raw project ID
            data.selectedProject = projectPopup.selectedItem?.title
        }
        expandedService = nil
        onRefresh?()
    }

    private func updateProjectDropdown() {
        let prevSel = data.selectedProject
        projectPopup.removeAllItems()

        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor
        ]
        let costAttrs: [NSAttributedString.Key: Any] = [.font: mono]

        func makeItem(_ name: String, yesterday: Double, rolling7d: Double) -> NSMenuItem {
            let item = NSMenuItem()
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: name + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
            s.append(NSAttributedString(string: "yday ", attributes: dimAttrs))
            s.append(NSAttributedString(string: fmtD(yesterday), attributes: costAttrs))
            s.append(NSAttributedString(string: "  7d ", attributes: dimAttrs))
            s.append(NSAttributedString(string: fmtD(rolling7d, cents: false), attributes: costAttrs))
            item.attributedTitle = s
            item.title = name  // used for identification
            return item
        }

        // "All Projects"
        let allItem = makeItem("All Projects", yesterday: data.yesterdaySpend, rolling7d: data.rolling7d)
        projectPopup.menu?.addItem(allItem)

        // Separator
        projectPopup.menu?.addItem(NSMenuItem.separator())

        // Per-project, sorted by 7d cost descending
        let sorted = data.allProjects.sorted {
            (data.projectCosts[$0]?.rolling7d ?? 0) > (data.projectCosts[$1]?.rolling7d ?? 0)
        }
        for p in sorted {
            let costs = data.projectCosts[p]
            let item = makeItem(p, yesterday: costs?.yesterday ?? 0, rolling7d: costs?.rolling7d ?? 0)
            projectPopup.menu?.addItem(item)
        }

        // Restore selection
        if let sel = prevSel {
            for i in 0..<projectPopup.numberOfItems {
                if projectPopup.item(at: i)?.title == sel {
                    projectPopup.selectItem(at: i); return
                }
            }
        }
        projectPopup.selectItem(at: 0)
    }

    // MARK: Update

    func update() {
        switch mode {
        case .overview: updateOverview()
        case .dayDetail(let d): updateDayDetail(d)
        case .settings: break
        }
        // Update timestamp
        if let lbl = footerView.viewWithTag(999) as? NSTextField {
            lbl.stringValue = "Updated \(relativeTime(data.lastUpdate))"
            lbl.textColor = data.error != nil ? .systemOrange : .secondaryLabelColor
        }
        // Error banner
        showErrorBanner(data.error)
    }

    private func showErrorBanner(_ error: String?) {
        // Remove existing banner
        view.viewWithTag(777)?.removeFromSuperview()
        guard let error = error else { return }

        let banner = FlippedView(frame: NSRect(x: 0, y: 0, width: POP_W, height: 28))
        banner.wantsLayer = true; banner._tag = 777
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor

        let icon = NSTextField(labelWithString: "\u{26A0}")
        icon.font = .systemFont(ofSize: 12)
        icon.frame = NSRect(x: PAD, y: 4, width: 18, height: 20)
        banner.addSubview(icon)

        let msg = NSTextField(labelWithString: error)
        msg.font = .systemFont(ofSize: 11, weight: .medium)
        msg.textColor = .systemOrange
        msg.frame = NSRect(x: PAD + 20, y: 6, width: POP_W - 2 * PAD - 80, height: 16)
        banner.addSubview(msg)

        let retry = NSButton(title: "Retry", target: self, action: #selector(refreshTap))
        retry.bezelStyle = .inline; retry.font = .systemFont(ofSize: 10, weight: .medium)
        retry.sizeToFit(); retry.frame.size.height = 20
        retry.frame.origin = NSPoint(x: POP_W - PAD - retry.frame.width, y: 4)
        banner.addSubview(retry)

        view.addSubview(banner, positioned: .above, relativeTo: nil)
    }

    // MARK: Overview

    private func updateOverview() {
        drawHeader()
        updateProjectDropdown()
        filterView.isHidden = false
        chartView.days = data.displayDays
        chartView.top5 = data.top5Names
        chartView.colorFor = { [weak self] name in self?.data.colorFor(name) ?? .systemGray }
        chartView.setNeedsDisplay(chartView.bounds)
        chartView.isHidden = false
        settingsContainer?.isHidden = true
        rebuildServiceRows(nil)
        layoutFrames()
    }

    private func drawHeader() {
        headerView.subviews.forEach { $0.removeFromSuperview() }
        let w = POP_W

        // Row 1: MTD
        let mtdLabel = NSTextField(labelWithString: "Month to Date")
        mtdLabel.font = .systemFont(ofSize: 10); mtdLabel.textColor = .secondaryLabelColor
        mtdLabel.frame = NSRect(x: PAD, y: 8, width: 100, height: 14)
        headerView.addSubview(mtdLabel)

        let mtdVal = NSTextField(labelWithString: fmtD(data.mtd))
        mtdVal.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        mtdVal.frame = NSRect(x: PAD, y: 22, width: 160, height: 26)
        headerView.addSubview(mtdVal)

        // Rolling 7-day total (center column)
        let r7Label = NSTextField(labelWithString: "Last 7 Days")
        r7Label.font = .systemFont(ofSize: 10); r7Label.textColor = .secondaryLabelColor
        r7Label.alignment = .center
        r7Label.frame = NSRect(x: w / 2 - 60, y: 8, width: 120, height: 14)
        headerView.addSubview(r7Label)

        let r7Val = NSTextField(labelWithString: fmtD(data.rolling7d))
        r7Val.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        r7Val.alignment = .center
        r7Val.frame = NSRect(x: w / 2 - 60, y: 22, width: 120, height: 18)
        headerView.addSubview(r7Val)

        // Billing day + burn rate
        let dayBurn = "Day \(data.dayOfMonth)/\(data.daysInMonth)  \u{00B7}  \(fmtD(data.burnRate))/day"
        let dayBurnLbl = NSTextField(labelWithString: dayBurn)
        dayBurnLbl.font = .systemFont(ofSize: 9); dayBurnLbl.textColor = .tertiaryLabelColor
        dayBurnLbl.alignment = .center
        dayBurnLbl.frame = NSRect(x: w / 2 - 80, y: 38, width: 160, height: 12)
        headerView.addSubview(dayBurnLbl)

        // Budget label
        if data.budget > 0 {
            let budLbl = NSTextField(labelWithString: "Budget: \(fmtD(data.budget, cents: false))")
            budLbl.font = .systemFont(ofSize: 10); budLbl.textColor = .secondaryLabelColor
            budLbl.alignment = .right
            budLbl.frame = NSRect(x: w - PAD - 140, y: 8, width: 140, height: 14)
            headerView.addSubview(budLbl)
        }

        // Forecast
        let fcLabel = NSTextField(labelWithString: "EOM Forecast")
        fcLabel.font = .systemFont(ofSize: 10); fcLabel.textColor = .secondaryLabelColor
        fcLabel.alignment = .right
        fcLabel.frame = NSRect(x: w - PAD - 140, y: 8, width: 140, height: 14)
        // Only show forecast label if no budget label
        if data.budget <= 0 { headerView.addSubview(fcLabel) }

        let fcDiff = data.forecast - data.prevMonthTotal
        let hasPrev = data.prevMonthTotal > 0
        var arrow = ""
        if hasPrev && fcDiff > 1 { arrow = " \u{2191}" }
        else if hasPrev && fcDiff < -1 { arrow = " \u{2193}" }
        var fcColor: NSColor = .labelColor
        if hasPrev && fcDiff > 1 { fcColor = .systemRed }
        else if hasPrev && fcDiff < -1 { fcColor = .systemGreen }
        let fcText = "~\(fmtD(data.forecast, cents: false))\(arrow)"
        let fcVal = NSTextField(labelWithString: fcText)
        fcVal.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        fcVal.textColor = fcColor
        fcVal.alignment = .right
        fcVal.frame = NSRect(x: w - PAD - 140, y: 26, width: 140, height: 18)
        headerView.addSubview(fcVal)

        // Budget progress bar (row 2)
        if data.budget > 0 {
            let barY: CGFloat = 50
            let barW = w - 2 * PAD
            let pct = min(data.mtd / data.budget, 1.5)

            // Track
            let track = NSView(frame: NSRect(x: PAD, y: barY, width: barW, height: 6))
            track.wantsLayer = true
            track.layer?.cornerRadius = 3
            track.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            headerView.addSubview(track)

            // Fill
            let fillW = barW * CGFloat(min(pct, 1.0))
            let fill = NSView(frame: NSRect(x: PAD, y: barY, width: fillW, height: 6))
            fill.wantsLayer = true; fill.layer?.cornerRadius = 3
            let bColor: NSColor = pct < 0.7 ? .systemGreen : pct < 1.0 ? .systemOrange : .systemRed
            fill.layer?.backgroundColor = bColor.cgColor
            headerView.addSubview(fill)

            // Pct label
            let pctLbl = NSTextField(labelWithString: "\(Int(pct * 100))%")
            pctLbl.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            pctLbl.textColor = .secondaryLabelColor
            pctLbl.frame = NSRect(x: w - PAD - 36, y: barY + 8, width: 36, height: 12)
            pctLbl.alignment = .right
            headerView.addSubview(pctLbl)
        }

        // Credits/discount row
        let credY: CGFloat = data.budget > 0 ? 68 : 52
        let credLbl = NSTextField(labelWithString: "")
        credLbl.font = .systemFont(ofSize: 10)
        credLbl.frame = NSRect(x: PAD, y: credY, width: w - 2 * PAD, height: 14)
        if data.discountAmt > 0.01 {
            var credStr = "Credits: \(fmtD(-data.discountAmt))"
            if data.prevMonthCost > 0 {
                let pctStr = String(format: "%.1f", data.discountPct)
                let prevStr = fmtD(data.prevMonthTotal, cents: false)
                credStr += "  (\(pctStr)% of prev \(prevStr))"
            }
            credLbl.stringValue = credStr
            credLbl.textColor = .systemGreen
        } else if data.prevMonthTotal > 0 {
            let prevStr = fmtD(data.prevMonthTotal, cents: false)
            credLbl.stringValue = "No credits this month  |  Prev month: \(prevStr)"
            credLbl.textColor = .tertiaryLabelColor
        } else {
            credLbl.stringValue = "No billing history for previous month"
            credLbl.textColor = .tertiaryLabelColor
        }
        headerView.addSubview(credLbl)

        // Separator at bottom of header
        let sep = NSView(frame: NSRect(x: 0, y: HDR_H - 0.5, width: w, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        headerView.addSubview(sep)
    }

    // MARK: Service Rows

    private func rebuildServiceRows(_ forDate: String?) {
        docView.subviews.forEach { $0.removeFromSuperview() }
        currentDateFilter = forDate

        var services: [(name: String, cost: Double, credits: Double, pctChange: Double?)] = []
        if let date = forDate {
            guard let day = data.displayDays.first(where: { $0.date == date }) ??
                            data.days.first(where: { $0.date == date }) else { return }
            services = day.services.map { svc in
                (svc.name, svc.cost, svc.credits, data.pctChangeDay(svc.name, date: date))
            }
        } else {
            var totals: [String: (cost: Double, credits: Double)] = [:]
            for d in data.displayDays {
                for s in d.services {
                    let cur = totals[s.name] ?? (0, 0)
                    totals[s.name] = (cur.cost + s.cost, cur.credits + s.credits)
                }
            }
            services = totals.map { (name: $0.key, cost: $0.value.cost, credits: $0.value.credits,
                                     pctChange: data.pctChange7d($0.key)) }
        }

        services.sort { ($0.cost + $0.credits) > ($1.cost + $1.credits) }
        let visible = services.filter { $0.cost + $0.credits > 0.001 }
        let maxCost = visible.first.map { $0.cost + $0.credits } ?? 1

        var yPos: CGFloat = 0
        for (i, svc) in visible.enumerated() {
            let sub = svc.cost + svc.credits
            let row = createServiceRow(svc.name, cost: svc.cost, credits: svc.credits,
                                       sub: sub, maxCost: maxCost, pctChange: svc.pctChange,
                                       y: yPos, idx: i)
            docView.addSubview(row)
            yPos += ROW_H

            // SKU sub-rows if this service is expanded
            if expandedService == svc.name {
                let cacheKey = "\(svc.name)|\(forDate ?? "7d")"
                if let skus = data.skuCache[cacheKey] {
                    for sku in skus where (sku.cost + sku.credits) > 0.001 {
                        let skuSub = sku.cost + sku.credits
                        let skuRow = createSKURow(sku.sku, cost: skuSub, maxCost: sub, y: yPos)
                        docView.addSubview(skuRow)
                        yPos += 28
                    }
                } else {
                    // Loading indicator
                    let loadLbl = NSTextField(labelWithString: "Loading SKUs...")
                    loadLbl.font = .systemFont(ofSize: 10, weight: .medium)
                    loadLbl.textColor = .secondaryLabelColor
                    loadLbl.frame = NSRect(x: PAD + DOT_SZ + 16, y: yPos + 4, width: 200, height: 16)
                    docView.addSubview(loadLbl)
                    yPos += 28
                }
            }
        }

        docView.frame.size.height = yPos
    }

    private func createSKURow(_ name: String, cost: Double, maxCost: Double, y: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: y, width: POP_W, height: 28))
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor

        let indent: CGFloat = PAD + DOT_SZ + 16
        let lbl = NSTextField(labelWithString: name)
        lbl.font = .systemFont(ofSize: 10); lbl.textColor = .secondaryLabelColor
        lbl.lineBreakMode = .byTruncatingTail
        lbl.frame = NSRect(x: indent, y: 4, width: POP_W - indent - COST_COL_W - PAD - 8, height: 14)
        row.addSubview(lbl)

        let costLbl = NSTextField(labelWithString: fmtD(cost))
        costLbl.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        costLbl.textColor = .secondaryLabelColor
        costLbl.alignment = .right
        costLbl.frame = NSRect(x: POP_W - PAD - COST_COL_W, y: 4, width: COST_COL_W, height: 14)
        row.addSubview(costLbl)

        let sep = NSView(frame: NSRect(x: indent, y: 0, width: POP_W - indent, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        row.addSubview(sep)

        return row
    }

    private func createServiceRow(_ name: String, cost: Double, credits: Double,
                                   sub: Double, maxCost: Double, pctChange: Double?,
                                   y: CGFloat, idx: Int) -> NSView {
        let row = HoverView(frame: NSRect(x: 0, y: y, width: POP_W, height: ROW_H))
        let isExpanded = expandedService == name

        // Click to expand/collapse SKU breakdown
        row.onClick = { [weak self] in
            guard let self = self else { return }
            if self.expandedService == name {
                self.expandedService = nil
            } else {
                self.expandedService = name
                // Fetch SKUs if not cached
                let cacheKey = "\(name)|\(self.currentDateFilter ?? "7d")"
                if self.data.skuCache[cacheKey] == nil {
                    self.data.fetchSKUs(service: name, forDate: self.currentDateFilter, cfg: self.cfg) { [weak self] _ in
                        self?.rebuildServiceRows(self?.currentDateFilter)
                        self?.layoutFrames()
                    }
                }
            }
            self.rebuildServiceRows(self.currentDateFilter)
            self.layoutFrames()
        }

        // Expand indicator
        let chevron = isExpanded ? "\u{25BC}" : "\u{25B6}"  // ▼ or ▶
        let chevLbl = NSTextField(labelWithString: chevron)
        chevLbl.font = .systemFont(ofSize: 7)
        chevLbl.textColor = .tertiaryLabelColor
        chevLbl.frame = NSRect(x: PAD + DOT_SZ + 10 + (POP_W - PAD * 2 - DOT_SZ - COST_BAR_W - COST_COL_W - 80), y: 12, width: 10, height: 14)
        row.addSubview(chevLbl)

        // Colored dot — aligned with service name (first text line at y=10, 16pt tall)
        let dotY: CGFloat = 10 + (16 - DOT_SZ) / 2  // vertically center with name label
        let dot = NSView(frame: NSRect(x: PAD, y: dotY, width: DOT_SZ, height: DOT_SZ))
        dot.wantsLayer = true; dot.layer?.cornerRadius = DOT_SZ / 2
        dot.layer?.backgroundColor = data.colorFor(name).cgColor
        row.addSubview(dot)

        // Service name
        let nameX = PAD + DOT_SZ + 8
        let nameLbl = NSTextField(labelWithString: name)
        nameLbl.font = .systemFont(ofSize: 12)
        nameLbl.lineBreakMode = .byTruncatingTail
        nameLbl.frame = NSRect(x: nameX, y: 10, width: POP_W - nameX - COST_BAR_W - COST_COL_W - 60 - PAD,
                               height: 16)
        row.addSubview(nameLbl)

        // Credits subtitle if any
        if credits < -0.01 {
            let credLbl = NSTextField(labelWithString: "incl. \(fmtD(credits)) credits")
            credLbl.font = .systemFont(ofSize: 9); credLbl.textColor = .systemGreen
            credLbl.frame = NSRect(x: nameX, y: 26, width: 160, height: 12)
            row.addSubview(credLbl)
        }

        // Inline cost bar
        let barX = POP_W - PAD - COST_COL_W - 58 - COST_BAR_W
        let barTrack = NSView(frame: NSRect(x: barX, y: (ROW_H - 5) / 2, width: COST_BAR_W, height: 5))
        barTrack.wantsLayer = true; barTrack.layer?.cornerRadius = 2.5
        barTrack.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        row.addSubview(barTrack)

        let fillW = COST_BAR_W * CGFloat(sub / maxCost)
        let barFill = NSView(frame: NSRect(x: barX, y: (ROW_H - 5) / 2, width: fillW, height: 5))
        barFill.wantsLayer = true; barFill.layer?.cornerRadius = 2.5
        barFill.layer?.backgroundColor = data.colorFor(name).withAlphaComponent(0.4).cgColor
        row.addSubview(barFill)

        // Cost value
        let costLbl = NSTextField(labelWithString: fmtD(sub))
        costLbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        costLbl.alignment = .right
        costLbl.frame = NSRect(x: POP_W - PAD - COST_COL_W - 54, y: (ROW_H - 16) / 2,
                               width: COST_COL_W, height: 16)
        row.addSubview(costLbl)

        // Pct change badge
        if let (text, color) = fmtPct(pctChange) {
            let badge = NSTextField(labelWithString: text)
            badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            badge.textColor = color; badge.alignment = .right
            badge.frame = NSRect(x: POP_W - PAD - 48, y: (ROW_H - 14) / 2, width: 44, height: 14)
            row.addSubview(badge)
        }

        // Separator
        if idx > 0 {
            let sep = NSView(frame: NSRect(x: PAD + DOT_SZ + 8, y: 0,
                                           width: POP_W - PAD - DOT_SZ - 8, height: 0.5))
            sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
            row.addSubview(sep)
        }

        return row
    }

    // MARK: Day Detail

    func chartDidSelect(_ date: String) {
        mode = .dayDetail(date)
        update()
    }

    private func updateDayDetail(_ date: String) {
        chartView.isHidden = true
        filterView.isHidden = true
        settingsContainer?.isHidden = true
        drawDayHeader(date)
        rebuildServiceRows(date)
        layoutFrames()
    }

    private func drawDayHeader(_ date: String) {
        headerView.subviews.forEach { $0.removeFromSuperview() }

        // Back button
        let back = NSButton(title: "\u{2190} 7 Days", target: self, action: #selector(backTap))
        back.bezelStyle = .inline; back.font = .systemFont(ofSize: 12, weight: .medium)
        back.contentTintColor = .linkColor
        back.sizeToFit(); back.frame.origin = NSPoint(x: PAD, y: 8)
        headerView.addSubview(back)

        // Date — prominent, right-aligned with DD/MM/YYYY format
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let dayNameFmt = DateFormatter(); dayNameFmt.dateFormat = "EEEE"
        let displayFmt = DateFormatter(); displayFmt.dateFormat = "dd/MM/yyyy"
        let parsed = f.date(from: date)
        let dayName = parsed.map { dayNameFmt.string(from: $0) } ?? ""
        let dateStr = parsed.map { displayFmt.string(from: $0) } ?? date

        let dayNameLbl = NSTextField(labelWithString: dayName)
        dayNameLbl.font = .systemFont(ofSize: 14, weight: .bold)
        dayNameLbl.alignment = .right
        dayNameLbl.frame = NSRect(x: POP_W - PAD - 200, y: 6, width: 200, height: 18)
        headerView.addSubview(dayNameLbl)

        let dateLbl = NSTextField(labelWithString: dateStr)
        dateLbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dateLbl.textColor = .secondaryLabelColor
        dateLbl.alignment = .right
        dateLbl.frame = NSRect(x: POP_W - PAD - 200, y: 24, width: 200, height: 16)
        headerView.addSubview(dateLbl)

        // Day total
        let day = data.displayDays.first(where: { $0.date == date }) ??
                  data.days.first(where: { $0.date == date })
        let total = day?.total ?? 0

        let totLbl = NSTextField(labelWithString: fmtD(total))
        totLbl.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        totLbl.frame = NSRect(x: PAD, y: 36, width: 160, height: 24)
        headerView.addSubview(totLbl)

        let totTitle = NSTextField(labelWithString: "Daily Total")
        totTitle.font = .systemFont(ofSize: 10); totTitle.textColor = .secondaryLabelColor
        totTitle.frame = NSRect(x: PAD + 2, y: 60, width: 80, height: 14)
        headerView.addSubview(totTitle)

        // vs previous day
        if let dayIdx = data.displayDays.firstIndex(where: { $0.date == date }), dayIdx > 0 {
            let prev = data.displayDays[dayIdx - 1]
            let diff = total - prev.total
            let pct = prev.total > 0 ? diff / prev.total * 100 : 0
            let sign = diff >= 0 ? "+" : ""
            let color: NSColor = diff > 0 ? .systemRed : .systemGreen
            let vsStr = "vs prev: \(sign)\(fmtD(diff)) (\(sign)\(Int(pct))%)"
            let vsLbl = NSTextField(labelWithString: vsStr)
            vsLbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            vsLbl.textColor = color; vsLbl.alignment = .right
            vsLbl.frame = NSRect(x: POP_W - PAD - 240, y: 42, width: 240, height: 16)
            headerView.addSubview(vsLbl)
        }

        // Separator
        let sep = NSView(frame: NSRect(x: 0, y: HDR_H - 0.5, width: POP_W, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        headerView.addSubview(sep)
    }

    @objc private func backTap() {
        mode = .overview; update()
    }

    // MARK: Settings

    private func showSettings() {
        mode = .settings
        chartView.isHidden = true
        filterView.isHidden = true
        headerView.subviews.forEach { $0.removeFromSuperview() }

        // Settings header
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        title.frame = NSRect(x: PAD, y: 10, width: 100, height: 20)
        headerView.addSubview(title)

        let done = NSButton(title: "Done", target: self, action: #selector(settingsDone))
        done.bezelStyle = .inline; done.font = .systemFont(ofSize: 12, weight: .semibold)
        done.sizeToFit(); done.frame.size.height = 24
        done.frame.origin = NSPoint(x: POP_W - PAD - done.frame.width, y: 8)
        headerView.addSubview(done)

        let sep = NSView(frame: NSRect(x: 0, y: HDR_H - 0.5, width: POP_W, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        headerView.addSubview(sep)

        // Build settings content in scroll view
        docView.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0

        // GCP Connection section
        y = addSectionHeader("GCP CONNECTION", y: y)
        (projField, y) = addTextField("Project ID", value: cfg.projectId, y: y)
        (dsField, y) = addTextField("Dataset", value: cfg.datasetId, y: y)
        (tblField, y) = addTextField("Table", value: cfg.tableId, y: y)

        // Test connection button
        let testBtn = NSButton(title: "Test Connection", target: self, action: #selector(testConn))
        testBtn.bezelStyle = .inline; testBtn.font = .systemFont(ofSize: 11, weight: .medium)
        testBtn.sizeToFit(); testBtn.frame.size.height = 24
        testBtn.frame.origin = NSPoint(x: POP_W - PAD - testBtn.frame.width, y: y + 4)
        testBtn.tag = 888
        docView.addSubview(testBtn)
        y += 34

        // Display section
        y = addSectionHeader("DISPLAY", y: y)
        refreshSeg = NSSegmentedControl(labels: REFRESH_LABELS, trackingMode: .selectOne,
                                         target: nil, action: nil)
        refreshSeg!.frame = NSRect(x: POP_W / 2, y: y + 4, width: POP_W / 2 - PAD, height: 22)
        refreshSeg!.selectedSegment = REFRESH_VALUES.firstIndex(of: cfg.refreshMin) ?? 1
        let refLbl = NSTextField(labelWithString: "Refresh Interval")
        refLbl.font = .systemFont(ofSize: 11); refLbl.textColor = .secondaryLabelColor
        refLbl.frame = NSRect(x: PAD, y: y + 6, width: 120, height: 16)
        docView.addSubview(refLbl); docView.addSubview(refreshSeg!)
        y += 32

        displaySeg = NSSegmentedControl(labels: DISPLAY_LABELS, trackingMode: .selectOne,
                                         target: nil, action: nil)
        displaySeg!.frame = NSRect(x: POP_W / 2, y: y + 4, width: POP_W / 2 - PAD, height: 22)
        displaySeg!.selectedSegment = DISPLAY_VALUES.firstIndex(of: cfg.displayMode) ?? 0
        let dispLbl = NSTextField(labelWithString: "Menu Bar Shows")
        dispLbl.font = .systemFont(ofSize: 11); dispLbl.textColor = .secondaryLabelColor
        dispLbl.frame = NSRect(x: PAD, y: y + 6, width: 120, height: 16)
        docView.addSubview(dispLbl); docView.addSubview(displaySeg!)
        y += 32

        let budLbl = NSTextField(labelWithString: "Monthly Budget ($)")
        budLbl.font = .systemFont(ofSize: 11); budLbl.textColor = .secondaryLabelColor
        budLbl.frame = NSRect(x: PAD, y: y + 6, width: 130, height: 16)
        docView.addSubview(budLbl)
        budgetField = NSTextField(frame: NSRect(x: POP_W / 2, y: y + 4, width: 100, height: 22))
        budgetField!.stringValue = cfg.monthlyBudget > 0 ? String(Int(cfg.monthlyBudget)) : ""
        budgetField!.placeholderString = "0 = disabled"
        budgetField!.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        budgetField!.bezelStyle = .roundedBezel
        docView.addSubview(budgetField!)
        y += 32

        // Alerts section
        y = addSectionHeader("NOTIFICATIONS", y: y)
        alertCheck = NSButton(checkboxWithTitle: "Budget alerts", target: nil, action: nil)
        alertCheck!.state = cfg.enableAlerts ? .on : .off
        alertCheck!.font = .systemFont(ofSize: 11)
        alertCheck!.frame = NSRect(x: PAD, y: y + 4, width: 120, height: 20)
        docView.addSubview(alertCheck!)

        alertSeg = NSSegmentedControl(labels: ALERT_LABELS, trackingMode: .selectOne,
                                       target: nil, action: nil)
        alertSeg!.frame = NSRect(x: POP_W / 2, y: y + 4, width: POP_W / 2 - PAD, height: 22)
        alertSeg!.selectedSegment = ALERT_VALUES.firstIndex(of: cfg.alertPct) ?? 1
        docView.addSubview(alertSeg!)
        y += 30

        docView.frame.size.height = y + 10
        layoutFrames()
    }

    private func addSectionHeader(_ title: String, y: CGFloat) -> CGFloat {
        let hdr = NSView(frame: NSRect(x: 0, y: y, width: POP_W, height: 28))
        hdr.wantsLayer = true
        hdr.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 11, weight: .bold)
        lbl.textColor = .secondaryLabelColor
        lbl.frame = NSRect(x: PAD, y: 6, width: POP_W - 2 * PAD, height: 16)
        hdr.addSubview(lbl)
        docView.addSubview(hdr)
        return y + 28
    }

    private func addTextField(_ label: String, value: String, y: CGFloat) -> (NSTextField, CGFloat) {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 11); lbl.textColor = .secondaryLabelColor
        lbl.frame = NSRect(x: PAD, y: y + 6, width: 100, height: 16)
        docView.addSubview(lbl)

        let field = NSTextField(frame: NSRect(x: PAD + 106, y: y + 4,
                                              width: POP_W - PAD - 112, height: 22))
        field.stringValue = value
        field.font = .systemFont(ofSize: 11); field.bezelStyle = .roundedBezel
        docView.addSubview(field)
        return (field, y + 30)
    }

    @objc private func settingsDone() {
        cfg.projectId = projField?.stringValue ?? cfg.projectId
        cfg.datasetId = dsField?.stringValue ?? cfg.datasetId
        cfg.tableId = tblField?.stringValue ?? cfg.tableId
        cfg.refreshMin = REFRESH_VALUES[refreshSeg?.selectedSegment ?? 1]
        cfg.displayMode = DISPLAY_VALUES[displaySeg?.selectedSegment ?? 0]
        cfg.monthlyBudget = Double(budgetField?.stringValue ?? "0") ?? 0
        cfg.enableAlerts = alertCheck?.state == .on
        cfg.alertPct = ALERT_VALUES[alertSeg?.selectedSegment ?? 1]
        cfg.save()

        onConfigChanged?(cfg)
        mode = .overview
        update()
    }

    @objc private func testConn() {
        let tmpCfg = Cfg(
            projectId: projField?.stringValue ?? "",
            datasetId: dsField?.stringValue ?? "",
            tableId: tblField?.stringValue ?? "",
            refreshMin: 30, displayMode: "today", monthlyBudget: 0,
            alertPct: 80, enableAlerts: false, enableDaily: false
        )
        // Find test button and show spinner
        if let btn = docView.viewWithTag(888) as? NSButton {
            btn.title = "Testing..."; btn.isEnabled = false
        }
        Auth.shared.getToken { [weak self] token in
            guard let token = token else {
                DispatchQueue.main.async { self?.testResult(false, "Auth failed") }; return
            }
            let tbl = "`\(tmpCfg.projectId).\(tmpCfg.datasetId).\(tmpCfg.tableId)`"
            let q = "SELECT 1 FROM \(tbl) LIMIT 1"
            BQ.query(q, project: tmpCfg.projectId, token: token) { rows in
                DispatchQueue.main.async {
                    self?.testResult(rows != nil, rows != nil ? "Connected" : "Query failed")
                }
            }
        }
    }

    private func testResult(_ ok: Bool, _ msg: String) {
        if let btn = docView.viewWithTag(888) as? NSButton {
            btn.title = ok ? "\u{2713} \(msg)" : "\u{2717} \(msg)"
            btn.contentTintColor = ok ? .systemGreen : .systemRed
            btn.isEnabled = true
            btn.sizeToFit(); btn.frame.size.height = 24
        }
    }

    // MARK: Layout

    private func layoutFrames() {
        let filterH_actual: CGFloat = filterView.isHidden ? 0 : FILTER_H
        let chartH_actual: CGFloat = chartView.isHidden ? 0 : CHART_H
        let scrollY = HDR_H + filterH_actual + chartH_actual
        let docH = docView.frame.height
        let maxScrollH = POP_MAX_H - HDR_H - filterH_actual - chartH_actual - FTR_H
        let scrollH = min(max(docH, ROW_H * 3), maxScrollH)
        let totalH = HDR_H + filterH_actual + chartH_actual + scrollH + FTR_H

        headerView.frame = NSRect(x: 0, y: 0, width: POP_W, height: HDR_H)
        filterView.frame = NSRect(x: 0, y: HDR_H, width: POP_W, height: FILTER_H)
        chartView.frame = NSRect(x: 0, y: HDR_H + filterH_actual, width: POP_W, height: CHART_H)
        scrollView.frame = NSRect(x: 0, y: scrollY, width: POP_W, height: scrollH)
        footerView.frame = NSRect(x: 0, y: scrollY + scrollH, width: POP_W, height: FTR_H)
        view.frame.size = NSSize(width: POP_W, height: totalH)

        preferredContentSize = NSSize(width: POP_W, height: totalH)
    }
}


// MARK: ─── Hover View ───────────────────────────────────────────────

class HoverView: NSView {
    private var tracking: NSTrackingArea?
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) { onClick?() }
    }
}

// MARK: ─── App Delegate ─────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var mainVC: MainVC!
    let data = DataMgr()
    var cfg: Cfg!
    var timer: Timer?
    var lastAlertDate: String?  // "yyyy-MM-dd" — fire at most once per day
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        cfg = Cfg.load()
        data.budget = cfg.monthlyBudget

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = sf("cloud", 14, .medium)
            btn.image?.isTemplate = true
            btn.imagePosition = .imageLeading
            btn.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            btn.title = ""
            btn.action = #selector(togglePopover)
            btn.target = self
        }

        // Popover
        mainVC = MainVC(data: data, cfg: cfg)
        mainVC.onRefresh = { [weak self] in self?.fetchData() }
        mainVC.onQuit = { NSApp.terminate(nil) }
        mainVC.onConsole = { [weak self] in self?.openConsole() }
        mainVC.onExecReport = { [weak self] in self?.runExecReport() }
        mainVC.onConfigChanged = { [weak self] newCfg in
            self?.cfg = newCfg
            self?.data.budget = newCfg.monthlyBudget
            self?.setupTimer()
            self?.fetchData()
        }

        popover = NSPopover()
        popover.contentViewController = mainVC
        popover.behavior = .applicationDefined
        popover.delegate = self

        // Initial fetch
        fetchData()
        setupTimer()

        // Request notification permission (requires .app bundle)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func setupTimer() {
        timer?.invalidate()
        if cfg.refreshMin < 0 {
            // Manual only — no timer
            return
        }
        if cfg.refreshMin == 0 {
            // Smart 2x daily: 7:00 AM and 1:00 PM
            scheduleNextSmartRefresh()
            return
        }
        // Fixed interval (hourly etc.)
        let interval = TimeInterval(cfg.refreshMin * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchData()
        }
    }

    private func scheduleNextSmartRefresh() {
        timer?.invalidate()
        let cal = Calendar.current
        let now = Date()
        let today7am = cal.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        let today1pm = cal.date(bySettingHour: 13, minute: 0, second: 0, of: now)!
        let tomorrow7am = cal.date(byAdding: .day, value: 1, to: today7am)!

        let next: Date
        if now < today7am { next = today7am }
        else if now < today1pm { next = today1pm }
        else { next = tomorrow7am }

        let delay = next.timeIntervalSince(now)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fetchData()
            self?.scheduleNextSmartRefresh()
        }
    }

    func fetchData() {
        data.refresh(cfg) { [weak self] ok in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.updateMenuBar()
                if self.popover.isShown { self.mainVC.update() }
                if ok { self.checkAlerts() }
            }
        }
    }

    private func updateMenuBar() {
        guard let btn = statusItem.button else { return }
        let val = data.menuValue(cfg.displayMode)
        let label = data.menuLabel(cfg.displayMode)
        let suffix = data.menuSuffix(cfg.displayMode)
        // Only show value once data has loaded
        if data.lastUpdate != nil {
            btn.title = " \(label)\(fmtD(val))\(suffix)"
        }

        // Budget tint
        if cfg.monthlyBudget > 0 {
            let dailyBudget = cfg.monthlyBudget / Double(data.daysInMonth)
            let pct = data.yesterdaySpend / dailyBudget
            if pct > 1.0 {
                btn.contentTintColor = .systemRed
            } else if pct > 0.7 {
                btn.contentTintColor = .systemOrange
            } else {
                btn.contentTintColor = nil  // default
            }
        } else {
            btn.contentTintColor = nil
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let btn = statusItem.button else { return }
        mainVC.cfg = cfg
        mainVC.mode = .overview
        _ = mainVC.view  // force loadView() if not yet loaded
        mainVC.update()
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Monitor for clicks outside the popover to dismiss it
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    private func openConsole() {
        let url = "https://console.cloud.google.com/billing?project=\(cfg.projectId)"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    private func runExecReport() {
        // Find the exec-report.sh script (next to the app bundle or in known location)
        let scriptPaths = [
            Bundle.main.bundlePath.replacingOccurrences(of: "CloudMeter.app/Contents/MacOS/CloudMeter", with: "") + "exec-report.sh",
            Bundle.main.bundlePath.replacingOccurrences(of: "CloudMeter.app", with: "exec-report.sh"),
            NSHomeDirectory() + "/Development/cloudmeter/exec-report.sh"
        ]
        guard let script = scriptPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("[ExecReport] exec-report.sh not found")
            return
        }

        // Show generating indicator
        if let btn = statusItem.button {
            btn.title = " Generating report..."
        }

        // Run in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script]
            proc.environment = ProcessInfo.processInfo.environment
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                print("[ExecReport] \(output)")
            } catch {
                print("[ExecReport] Failed: \(error)")
            }

            DispatchQueue.main.async {
                self?.updateMenuBar()
            }
        }
    }

    private func checkAlerts() {
        guard cfg.enableAlerts, cfg.monthlyBudget > 0 else { return }
        let today = DataMgr.todayString()
        guard today != lastAlertDate else { return }  // at most once per day
        let pct = data.mtd / cfg.monthlyBudget * 100
        if pct >= Double(cfg.alertPct) {
            lastAlertDate = today
            sendNotification(
                title: "GCP Spend Alert",
                body: "MTD spend \(fmtD(data.mtd)) has reached \(Int(pct))% of \(fmtD(cfg.monthlyBudget, cents: false)) budget"
            )
        }
    }

    private func sendNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func popoverDidClose(_ notification: Notification) {
        mainVC.mode = .overview
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

// MARK: ─── Entry Point ──────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
