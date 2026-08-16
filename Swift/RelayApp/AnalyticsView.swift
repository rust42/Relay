import SwiftUI
import Charts

/// One time bucket's rollup — the unit every trend chart in Analytics is
/// built from.
struct AnalyticsBucket: Identifiable {
    let id = UUID()
    let date: Date
    let count: Int
    let errorCount: Int
    let p50Ms: Double?
    let p95Ms: Double?
    let bytesTotal: UInt64

    var errorRate: Double { count == 0 ? 0 : Double(errorCount) / Double(count) * 100 }
}

/// Pure data-processing side of Analytics — turns the flat cross-session
/// event log into bucketed trends and a host ranking. No view code, so it's
/// easy to reason about (and change) independent of how it's drawn.
enum AnalyticsAggregator {
    /// Picks a bucket width that yields a readable number of points
    /// (roughly 24–60) regardless of how much history exists, snapped to a
    /// natural calendar unit rather than an arbitrary fraction.
    static func bucketSeconds(for events: [AnalyticsEventDisplay]) -> Double {
        guard let minMs = events.map(\.timestampMs).min(), let maxMs = events.map(\.timestampMs).max(), maxMs > minMs else {
            return 3600
        }
        let spanSeconds = Double(maxMs - minMs) / 1000
        let candidates: [Double] = [60, 300, 900, 1800, 3600, 3600 * 3, 3600 * 6, 3600 * 12, 86400, 86400 * 7]
        return candidates.first { spanSeconds / $0 <= 48 } ?? 86400 * 7
    }

    static func buckets(from events: [AnalyticsEventDisplay]) -> [AnalyticsBucket] {
        guard !events.isEmpty else { return [] }
        let width = bucketSeconds(for: events)
        var groups: [Int64: [AnalyticsEventDisplay]] = [:]
        for event in events {
            let bucketIndex = Int64((Double(event.timestampMs) / 1000 / width).rounded(.down))
            groups[bucketIndex, default: []].append(event)
        }
        return groups.keys.sorted().map { index in
            let group = groups[index]!
            let date = Date(timeIntervalSince1970: Double(index) * width)
            let errorCount = group.filter { ($0.statusCode ?? 0) >= 400 || $0.statusCode == nil }.count
            let latencies = group.compactMap { $0.durationMs.map(Double.init) }.sorted()
            return AnalyticsBucket(
                date: date,
                count: group.count,
                errorCount: errorCount,
                p50Ms: percentile(latencies, 0.5),
                p95Ms: percentile(latencies, 0.95),
                bytesTotal: group.reduce(0) { $0 + $1.bytesSent + $1.bytesReceived }
            )
        }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[index]
    }

    /// Top `limit` hosts by request count, most-requested first. Not
    /// folded into "Other" below the limit — Analytics is a diagnostic
    /// tool, not a public report, so trimming the list is enough.
    static func topHosts(from events: [AnalyticsEventDisplay], limit: Int) -> [(host: String, count: Int)] {
        var counts: [String: Int] = [:]
        for event in events {
            let host = event.host.isEmpty ? "(unknown)" : event.host
            counts[host, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }
}

/// Historical trends across sessions — the traffic list itself is
/// in-memory-only and wiped on stop/quit, but every request also appends a
/// compact event to a cross-session log on the Rust side, which is what
/// this reads. Fetched on appear/refresh, not kept live in sync.
struct AnalyticsView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var events: [AnalyticsEventDisplay] = []
    @State private var isLoading = true
    @State private var hoveredBucketID: AnalyticsBucket.ID?

    private var buckets: [AnalyticsBucket] { AnalyticsAggregator.buckets(from: events) }
    private var topHosts: [(host: String, count: Int)] { AnalyticsAggregator.topHosts(from: events, limit: 8) }

    private var errorRate: Double {
        guard !events.isEmpty else { return 0 }
        let errors = events.filter { ($0.statusCode ?? 0) >= 400 || $0.statusCode == nil }.count
        return Double(errors) / Double(events.count) * 100
    }

    private var medianLatencyMs: Double? {
        let sorted = events.compactMap { $0.durationMs.map(Double.init) }.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    private var totalBytes: UInt64 {
        events.reduce(0) { $0 + $1.bytesSent + $1.bytesReceived }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if isLoading {
                    loadingState
                } else if events.isEmpty {
                    emptyState
                } else {
                    statTiles
                    ChartCard(title: "REQUESTS OVER TIME") {
                        TrendChart(buckets: buckets, hoveredID: $hoveredBucketID, series: [
                            TrendSeries(label: "Requests", color: Theme.accent) { Double($0.count) }
                        ])
                    }
                    ChartCard(title: "LATENCY (p50 / p95)") {
                        TrendChart(buckets: buckets, hoveredID: $hoveredBucketID, series: [
                            TrendSeries(label: "p50", color: Theme.accent) { $0.p50Ms },
                            TrendSeries(label: "p95", color: Theme.accent2) { $0.p95Ms },
                        ], valueSuffix: " ms")
                    }
                    ChartCard(title: "ERROR RATE") {
                        TrendChart(buckets: buckets, hoveredID: $hoveredBucketID, series: [
                            TrendSeries(label: "Error rate", color: Theme.statusColor(500)) { $0.errorRate }
                        ], valueSuffix: "%")
                    }
                    ChartCard(title: "TOP HOSTS") {
                        TopHostsChart(hosts: topHosts)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ANALYTICS")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Text("Historical trends across sessions — \(events.count) events logged")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Refresh")
        }
    }

    private var statTiles: some View {
        HStack(spacing: 12) {
            StatTile(label: "TOTAL REQUESTS", value: "\(events.count)", icon: "tray.full")
            StatTile(label: "MEDIAN LATENCY", value: medianLatencyMs.map { "\(Int($0)) ms" } ?? "—", icon: "clock")
            StatTile(label: "ERROR RATE", value: String(format: "%.1f%%", errorRate), icon: "exclamationmark.triangle", tint: errorRate > 5 ? Theme.statusColor(500) : Theme.textPrimary)
            StatTile(label: "DATA TRANSFERRED", value: ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .binary), icon: "arrow.up.arrow.down")
        }
    }

    private var loadingState: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 26))
                .foregroundStyle(Theme.textTertiary)
            Text("No history yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Analytics builds up as you capture traffic — every request logs a compact event here, kept across launches.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func load() async {
        isLoading = true
        events = await proxyModel.fetchAnalyticsEvents()
        isLoading = false
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let icon: String
    var tint: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon)
                .labelStyle(.compact)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassPanel(cornerRadius: 10)
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            content
                .frame(height: 180)
        }
        .padding(14)
        .glassPanel(cornerRadius: 10)
    }
}

/// One line/area series in a `TrendChart` — a color assigned once, in the
/// fixed order the caller lists series in, never recomputed by rank.
struct TrendSeries {
    let label: String
    let color: Color
    let value: (AnalyticsBucket) -> Double?
}

/// A single-axis time-series chart shared by Requests/Latency/Error-rate —
/// one hover crosshair implementation reused three times rather than
/// three slightly-different ones. 1–2 series; a legend renders whenever
/// there's more than one, since color is never the only way to tell them
/// apart (the legend also carries the label as text).
private struct TrendChart: View {
    let buckets: [AnalyticsBucket]
    @Binding var hoveredID: AnalyticsBucket.ID?
    let series: [TrendSeries]
    var valueSuffix: String = ""

    private var hoveredBucket: AnalyticsBucket? {
        buckets.first { $0.id == hoveredID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if series.count > 1 {
                legend
            }
            chart
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(series, id: \.label) { s in
                HStack(spacing: 5) {
                    Circle().fill(s.color).frame(width: 6, height: 6)
                    Text(s.label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if let bucket = hoveredBucket {
                Text(bucket.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series, id: \.label) { s in
                ForEach(buckets) { bucket in
                    if let value = s.value(bucket) {
                        LineMark(x: .value("Time", bucket.date), y: .value(s.label, value))
                            .foregroundStyle(s.color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                }
                if series.count == 1 {
                    ForEach(buckets) { bucket in
                        if let value = s.value(bucket) {
                            AreaMark(x: .value("Time", bucket.date), y: .value(s.label, value))
                                .foregroundStyle(LinearGradient(colors: [s.color.opacity(0.18), s.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            if let bucket = hoveredBucket {
                RuleMark(x: .value("Time", bucket.date))
                    .foregroundStyle(Theme.hairlineBright)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(series, id: \.label) { s in
                    if let value = s.value(bucket) {
                        PointMark(x: .value("Time", bucket.date), y: .value(s.label, value))
                            .foregroundStyle(s.color)
                            .symbolSize(36)
                        PointMark(x: .value("Time", bucket.date), y: .value(s.label, value))
                            .annotation(position: .top) {
                                Text("\(Int(value))\(valueSuffix)")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 8.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 8.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let originX = geo[plotFrame].origin.x
                                guard let date: Date = proxy.value(atX: value.location.x - originX) else { return }
                                hoveredID = nearestBucket(to: date)?.id
                            }
                            .onEnded { _ in hoveredID = nil }
                    )
            }
        }
    }

    private func nearestBucket(to date: Date) -> AnalyticsBucket? {
        buckets.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

/// Ranked horizontal bars — one consistent hue (this is a single series,
/// request count, faceted by host; color would only decorate, not encode,
/// if it varied per bar). Values are direct-labeled rather than requiring
/// hover, since the whole point of a ranking is reading exact positions.
private struct TopHostsChart: View {
    let hosts: [(host: String, count: Int)]

    var body: some View {
        Chart(hosts, id: \.host) { entry in
            BarMark(x: .value("Requests", entry.count), y: .value("Host", entry.host))
                .foregroundStyle(Theme.accent3)
                .cornerRadius(3)
                .annotation(position: .trailing) {
                    Text("\(entry.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 8.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
