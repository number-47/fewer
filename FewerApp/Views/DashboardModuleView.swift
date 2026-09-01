import AppKit
import FewerCore
import SwiftUI

struct MonitorStatusItemContent {
    let texts: [String]
    let chartValue: Double?
    let chartHistory: [Double]
    let chartKind: MonitorWidgetKind?
    let color: NSColor
    let vertical: Bool
}

final class MonitorStatusItemView: NSView {
    var content = MonitorStatusItemContent(
        texts: ["—"],
        chartValue: nil,
        chartHistory: [],
        chartKind: nil,
        color: .controlAccentColor,
        vertical: false
    ) {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var onClick: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        if content.vertical && content.texts.count >= 2 {
            let mid = content.texts.count / 2
            let topTexts = Array(content.texts.prefix(mid))
            let bottomTexts = Array(content.texts.suffix(content.texts.count - mid))
            let topWidth = topTexts.reduce(CGFloat.zero) { $0 + NSAttributedString(string: $1, attributes: Self.attributes).size().width } + CGFloat(max(topTexts.count - 1, 0)) * 4
            let bottomWidth = bottomTexts.reduce(CGFloat.zero) { $0 + NSAttributedString(string: $1, attributes: Self.attributes).size().width } + CGFloat(max(bottomTexts.count - 1, 0)) * 4
            let chartExtra: CGFloat = content.chartValue == nil ? 8 : 26
            return NSSize(width: max(24, max(topWidth, bottomWidth) + chartExtra), height: 30)
        }
        let width = content.texts.reduce(CGFloat.zero) { $0 + NSAttributedString(string: $1, attributes: Self.attributes).size().width }
        return NSSize(width: max(24, width + CGFloat(max(content.texts.count - 1, 0)) * 4 + (content.chartValue == nil ? 8 : 26)), height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        if content.vertical && content.texts.count >= 2 {
            drawVertical()
            return
        }
        var x: CGFloat = 4
        for text in content.texts {
            let value = NSAttributedString(string: text, attributes: Self.attributes)
            value.draw(at: NSPoint(x: x, y: (bounds.height - value.size().height) / 2))
            x += value.size().width + 4
        }
        guard let chartValue = content.chartValue, let chartKind = content.chartKind else { return }
        let rect = NSRect(x: x, y: 5, width: 14, height: 12)
        NSColor.quaternaryLabelColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).stroke()
        let values = content.chartHistory.isEmpty ? [chartValue] : content.chartHistory
        switch chartKind {
        case .lineChart:
            drawLine(values, in: rect)
        case .barChart, .throughputChart:
            drawBars(values, in: rect)
        case .pieChart:
            drawPie(chartValue, in: rect)
        case .gauge:
            drawGauge(chartValue, in: rect)
        default:
            drawBars([chartValue], in: rect)
        }
    }

    private func drawVertical() {
        let mid = content.texts.count / 2
        let topTexts = Array(content.texts.prefix(mid))
        let bottomTexts = Array(content.texts.suffix(content.texts.count - mid))
        // Bottom row: texts + optional chart
        var x: CGFloat = 4
        let bottomY: CGFloat = 2
        for text in bottomTexts {
            let value = NSAttributedString(string: text, attributes: Self.attributes)
            value.draw(at: NSPoint(x: x, y: bottomY))
            x += value.size().width + 4
        }
        var chartX = x
        // Top row: texts
        x = 4
        let topY: CGFloat = bounds.height - 16
        for text in topTexts {
            let value = NSAttributedString(string: text, attributes: Self.attributes)
            value.draw(at: NSPoint(x: x, y: topY))
            x += value.size().width + 4
        }
        // Draw chart on bottom row
        guard let chartValue = content.chartValue, let chartKind = content.chartKind else { return }
        let rect = NSRect(x: chartX, y: bottomY + 1, width: 14, height: 12)
        NSColor.quaternaryLabelColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).stroke()
        let values = content.chartHistory.isEmpty ? [chartValue] : content.chartHistory
        switch chartKind {
        case .lineChart:
            drawLine(values, in: rect)
        case .barChart, .throughputChart:
            drawBars(values, in: rect)
        case .pieChart:
            drawPie(chartValue, in: rect)
        case .gauge:
            drawGauge(chartValue, in: rect)
        default:
            drawBars([chartValue], in: rect)
        }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }

    private func drawLine(_ values: [Double], in rect: NSRect) {
        let values = Array(values.suffix(20))
        guard values.count > 1 else { drawBars(values, in: rect); return }
        let path = NSBezierPath()
        for (index, value) in values.enumerated() {
            let progress = CGFloat(index) / CGFloat(values.count - 1)
            let point = NSPoint(
                x: rect.minX + rect.width * progress,
                y: rect.minY + rect.height * CGFloat(clamped(value))
            )
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        content.color.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawBars(_ values: [Double], in rect: NSRect) {
        let values = Array(values.suffix(4))
        guard !values.isEmpty else { return }
        let spacing: CGFloat = 1
        let width = max(1, (rect.width - CGFloat(values.count - 1) * spacing) / CGFloat(values.count))
        content.color.setFill()
        for (index, value) in values.enumerated() {
            let height = max(1, rect.height * CGFloat(clamped(value)))
            NSBezierPath(roundedRect: NSRect(x: rect.minX + CGFloat(index) * (width + spacing), y: rect.minY, width: width, height: height), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawPie(_ value: Double, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1
        let path = NSBezierPath()
        path.move(to: center)
        path.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + CGFloat(clamped(value)) * 360, clockwise: false)
        path.close()
        content.color.setFill()
        path.fill()
    }

    private func drawGauge(_ value: Double, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.minY + 2)
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: rect.width / 2 - 1, startAngle: 0, endAngle: 180 * CGFloat(clamped(value)), clockwise: false)
        content.color.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
}

struct MonitorModulePopoverView: View {
    let moduleID: SystemMonitorModuleID
    let openSettings: () -> Void
    let openSystemMonitor: () -> Void

    var body: some View {
        MenuBarPopoverChrome(
            title: moduleID.title,
            systemImage: moduleID.systemImage,
            openSettings: openSettings
        ) {
            VStack(spacing: 0) {
                MonitorModuleContent(moduleID: moduleID)

                Divider()

                Button(action: openSystemMonitor) {
                    Label(footerTitle, systemImage: footerSystemImage)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .accessibilityIdentifier("monitor.footer.\(moduleID.rawValue)")
            }
        }
        .frame(width: 280)
    }

    private var footerTitle: String {
        switch moduleID {
        case .disk: "打开磁盘工具"
        case .network: "打开网络监视器"
        case .cpu, .gpu, .memory: "打开活动监视器"
        }
    }

    private var footerSystemImage: String {
        moduleID == .disk ? "externaldrive" : "chart.bar.xaxis"
    }
}

/// 监控详情内容可嵌入工具箱；采样可见性随该内容的出现和消失更新。
struct MonitorModuleContent: View {
    let moduleID: SystemMonitorModuleID
    @ObservedObject private var metrics = SystemMetricsService.shared
    @StateObject private var wifiDetails = NetworkWiFiDetailsService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch moduleID {
            case .cpu: CPUDetailsView(
                snapshot: metrics.current.cpu,
                history: metrics.history.compactMap { $0.cpu?.total }
            )
            case .gpu: GPUDetailsView(snapshot: metrics.current.gpu, history: gpuHistory)
            case .memory: MemoryDetailsView(
                snapshot: metrics.current.memory,
                history: metrics.history.compactMap { $0.memory?.usageRatio }
            )
            case .disk: DiskDetailsView(
                snapshot: metrics.current.disk,
                history: metrics.history.compactMap(\.disk)
            )
            case .network:
                NetworkDetailsView(
                    downloadRate: metrics.current.networkInBytesPerSecond,
                    uploadRate: metrics.current.networkOutBytesPerSecond,
                    downloadHistory: metrics.history.map(\.networkInBytesPerSecond),
                    uploadHistory: metrics.history.map(\.networkOutBytesPerSecond),
                    interface: metrics.defaultNetworkInterface,
                    ipv4: metrics.localIPv4Address,
                    ipv6: metrics.localIPv6Address,
                    totalDownloaded: metrics.current.networkInBytes,
                    totalUploaded: metrics.current.networkOutBytes,
                    wifiDetails: wifiDetails
                )
            }
        }
        .padding(16)
        .onAppear { metrics.setModuleVisible(moduleID, isVisible: true) }
        .onDisappear { metrics.setModuleVisible(moduleID, isVisible: false) }
    }

    private var gpuHistory: [Double] {
        guard let deviceID = metrics.current.gpu?.selectedDevice?.id else { return [] }
        return metrics.history.compactMap { $0.gpu?.device(id: deviceID)?.utilization }
    }
}

private enum MonitorPopoverStyle {
    static func color(for moduleID: SystemMonitorModuleID) -> Color {
        switch moduleID {
        case .cpu: Color(nsColor: .systemBlue)
        case .gpu: Color(nsColor: .systemPurple)
        case .memory: Color(nsColor: .systemGreen)
        case .disk: Color(nsColor: .systemOrange)
        case .network: Color(nsColor: .systemTeal)
        }
    }
}

private struct MonitorCard<Content: View>: View {
    let title: String?
    let color: Color
    @ViewBuilder let content: Content

    init(_ title: String? = nil, color: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.color = color
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.5))
        }
    }
}

private struct MonitorMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

private struct MonitorTrendGraph: View {
    let values: [Double]
    let color: Color
    var upperBound: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            let visible = Array(values.suffix(60))
            if visible.count > 1 {
                let maximum = max(upperBound ?? (visible.max() ?? 1), 0.000_001)
                Path { path in
                    for (index, value) in visible.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(visible.count - 1)
                        let y = geometry.size.height * (1 - CGFloat(min(max(value / maximum, 0), 1)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, lineWidth: 1.5)
            } else {
                Text("暂无历史")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 52)
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MonitorDualTrendGraph: View {
    let firstValues: [Double]
    let secondValues: [Double]
    let firstColor: Color
    let secondColor: Color

    var body: some View {
        GeometryReader { geometry in
            let first = Array(firstValues.suffix(60))
            let second = Array(secondValues.suffix(60))
            let maximum = max(first.max() ?? 0, second.max() ?? 0, 0.000_001)
            if max(first.count, second.count) > 1 {
                trendPath(values: first, in: geometry.size, maximum: maximum)
                    .stroke(firstColor, lineWidth: 1.5)
                trendPath(values: second, in: geometry.size, maximum: maximum)
                    .stroke(secondColor, lineWidth: 1.5)
            } else {
                Text("暂无历史")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 52)
        .padding(8)
        .background(firstColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func trendPath(values: [Double], in size: CGSize, maximum: Double) -> Path {
        Path { path in
            guard values.count > 1 else { return }
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat(min(max(value / maximum, 0), 1)))
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}


private struct DiskDetailsView: View {
    let snapshot: DiskSnapshot?
    let history: [DiskSnapshot]

    var body: some View {
        Group {
            if let snapshot {
                let color = MonitorPopoverStyle.color(for: .disk)
                VStack(alignment: .leading, spacing: 12) {
                    MonitorCard(color: color) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(snapshot.volumeName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(percentage(snapshot.usageRatio)).font(.title2).monospacedDigit()
                        }
                        Text("\(bytes(snapshot.usedBytes)) / \(bytes(snapshot.totalBytes))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        MonitorTrendGraph(values: history.map(\.usageRatio), color: color, upperBound: 1)
                        MonitorMetricRow(title: "可用", value: bytes(snapshot.availableBytes))
                    }
                    MonitorCard("读写速度", color: color) {
                        MonitorMetricRow(title: "读取", value: rate(snapshot.readBytesPerSecond))
                        MonitorMetricRow(title: "写入", value: rate(snapshot.writeBytesPerSecond))
                        MonitorDualTrendGraph(
                            firstValues: history.compactMap(\.readBytesPerSecond),
                            secondValues: history.compactMap(\.writeBytesPerSecond),
                            firstColor: Color(nsColor: .systemBlue),
                            secondColor: Color(nsColor: .systemOrange)
                        )
                    }
                    MonitorCard("磁盘信息", color: color) {
                        MonitorMetricRow(title: "文件系统", value: snapshot.fileSystem ?? "不可用")
                        MonitorMetricRow(title: "连接", value: snapshot.connectionType ?? "不可用")
                        MonitorMetricRow(title: "设备", value: snapshot.deviceName ?? "不可用")
                        MonitorMetricRow(title: "累计读取", value: bytes(snapshot.readBytes))
                        MonitorMetricRow(title: "累计写入", value: bytes(snapshot.writeBytes))
                    }
                    MonitorCard("SMART 状态", color: color) {
                        smartDetails(snapshot.smart)
                    }
                }
            } else {
                ContentUnavailableView("磁盘数据不可用", systemImage: "internaldrive", description: Text("系统没有返回可读取的启动卷信息。"))
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }

    @ViewBuilder
    private func smartDetails(_ smart: DiskSMARTSnapshot?) -> some View {
        if let smart {
            MonitorMetricRow(title: "健康度", value: smart.health ?? "不可用")
            MonitorMetricRow(title: "温度", value: smart.temperatureCelsius.map { String(format: "%.0f℃", $0) } ?? "不可用")
            MonitorMetricRow(title: "寿命", value: smart.lifeRemainingPercent.map { String(format: "%.0f%%", $0) } ?? "不可用")
            MonitorMetricRow(title: "警告", value: smart.warning ?? "不可用")
            MonitorMetricRow(title: "通电时间", value: smart.powerOnHours.map { "\($0) 小时" } ?? "不可用")
        } else {
            MonitorMetricRow(title: "状态", value: "不可用")
        }
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "不可用" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "不可用" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct MemoryDetailsView: View {
    let snapshot: MemorySnapshot?
    let history: [Double]

    var body: some View {
        Group {
            if let snapshot {
                let color = MonitorPopoverStyle.color(for: .memory)
                VStack(alignment: .leading, spacing: 12) {
                    MonitorCard(color: color) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("内存使用").foregroundStyle(.secondary)
                            Spacer()
                            Text(percentage(snapshot.usageRatio)).font(.title2).monospacedDigit()
                        }
                        Text("\(bytes(snapshot.usedBytes)) / \(bytes(snapshot.totalBytes))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        MonitorTrendGraph(values: history, color: color, upperBound: 1)
                    }
                    MonitorCard("内存构成", color: color) {
                        MonitorMetricRow(title: "App", value: bytes(snapshot.appBytes))
                        MonitorMetricRow(title: "活跃", value: bytes(snapshot.activeBytes))
                        MonitorMetricRow(title: "Wired", value: bytes(snapshot.wiredBytes))
                        MonitorMetricRow(title: "Compressed", value: bytes(snapshot.compressedBytes))
                        MonitorMetricRow(title: "可用", value: bytes(snapshot.freeBytes))
                    }
                    MonitorCard("内存压力", color: color) {
                        MonitorMetricRow(title: "状态", value: snapshot.pressure?.level.rawValue ?? "不可用")
                        MonitorMetricRow(title: "Swap", value: swap(snapshot.swap))
                    }
                }
            } else {
                ContentUnavailableView("内存数据不可用", systemImage: "memorychip", description: Text("系统没有返回可读取的 Mach VM 内存统计。"))
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func swap(_ value: MemorySwapSnapshot?) -> String {
        guard let value else { return "不可用" }
        guard value.totalBytes > 0 || value.usedBytes > 0 || value.freeBytes > 0 else { return "未使用" }
        return "\(bytes(value.usedBytes)) / \(bytes(value.totalBytes))"
    }
}

private struct GPUDetailsView: View {
    let snapshot: GPUSnapshot?
    let history: [Double]

    var body: some View {
        Group {
            if let snapshot, let gpu = snapshot.selectedDevice {
                let color = MonitorPopoverStyle.color(for: .gpu)
                VStack(alignment: .leading, spacing: 12) {
                    MonitorCard(color: color) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("利用率").foregroundStyle(.secondary)
                            Spacer()
                            Text(percentage(gpu.utilization)).font(.title2).monospacedDigit()
                        }
                        MonitorTrendGraph(values: history, color: color, upperBound: 1)
                        HStack(spacing: 12) {
                            usage("Render", gpu.renderUtilization)
                            usage("Tiler", gpu.tilerUtilization)
                            usage("ANE", gpu.aneUtilization)
                        }
                    }
                    MonitorCard("GPU 信息", color: color) {
                        MonitorMetricRow(title: "设备", value: snapshot.selectedAutomatically ? "自动 · \(gpu.model)" : "已选 · \(gpu.model)")
                        MonitorMetricRow(title: "类型", value: gpu.type.rawValue)
                        MonitorMetricRow(title: "核心", value: gpu.coreCount.map(String.init) ?? "不可用")
                        MonitorMetricRow(title: "FPS", value: gpu.framesPerSecond.map { String(format: "%.0f", $0) } ?? "不可用")
                        MonitorMetricRow(title: "状态", value: gpu.isActive ? "可用" : "已关闭")
                        if snapshot.devices.count > 1 {
                            MonitorMetricRow(title: "已发现 GPU", value: "\(snapshot.devices.count)")
                        }
                    }
                }
            } else {
                ContentUnavailableView("GPU 数据不可用", systemImage: "memorychip", description: Text("系统没有返回可读取的 GPU 加速器。"))
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    private func usage(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(percentage(value)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percentage(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "不可用"
    }
}

private struct CPUDetailsView: View {
    let snapshot: CPUSnapshot?
    let history: [Double]

    var body: some View {
        Group {
            if let snapshot {
                let color = MonitorPopoverStyle.color(for: .cpu)
                VStack(alignment: .leading, spacing: 12) {
                    MonitorCard(color: color) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("利用率").foregroundStyle(.secondary)
                            Spacer()
                            Text(percentage(snapshot.total)).font(.title2).monospacedDigit()
                        }
                        MonitorTrendGraph(values: history, color: color, upperBound: 1)
                        HStack(spacing: 12) {
                            usage("用户", snapshot.user)
                            usage("系统", snapshot.system)
                            usage("空闲", snapshot.idle)
                        }
                    }
                    MonitorCard("基本信息", color: color) {
                        MonitorMetricRow(title: "平均负载", value: loadAverage(snapshot.loadAverage))
                        MonitorMetricRow(title: "运行时间", value: snapshot.uptime.map(uptime) ?? "不可用")
                        MonitorMetricRow(title: "频率", value: snapshot.frequencyHz.map(frequency) ?? "不可用")
                        MonitorMetricRow(title: "温度", value: snapshot.temperatureCelsius.map { String(format: "%.0f℃", $0) } ?? "不可用")
                        clusterDetails(snapshot.clusters)
                    }
                    MonitorCard("核心利用率", color: color) {
                        coreDetails(snapshot.cores)
                    }
                }
            } else {
                ContentUnavailableView("CPU 数据不可用", systemImage: "cpu", description: Text("首次采样或系统暂时无法读取 CPU 计数。"))
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    private func usage(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(percentage(value)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func coreDetails(_ cores: [CPUCoreSnapshot]) -> some View {
        if cores.isEmpty {
            MonitorMetricRow(title: "核心", value: "不可用")
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(cores.count, 3)), spacing: 4) {
                ForEach(cores) { core in
                    Text("\(core.id + 1) · \(percentage(core.total))")
                        .font(.caption2).monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func clusterDetails(_ clusters: [CPUClusterSnapshot]) -> some View {
        if clusters.isEmpty {
            MonitorMetricRow(title: "核心集群", value: "不可用")
        } else {
            ForEach(clusters) { cluster in
                MonitorMetricRow(title: cluster.name, value: "\(cluster.physicalCoreCount) 物理 / \(cluster.logicalCoreCount) 逻辑")
            }
        }
    }

    private func percentage(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func loadAverage(_ values: [Double]) -> String {
        guard values.count == 3 else { return "不可用" }
        return values.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }
    private func uptime(_ value: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: value) ?? "不可用"
    }
    private func frequency(_ value: UInt64) -> String { String(format: "%.2f GHz", Double(value) / 1_000_000_000) }
}

private struct NetworkDetailsView: View {
    let downloadRate: Double
    let uploadRate: Double
    let downloadHistory: [Double]
    let uploadHistory: [Double]
    let interface: String?
    let ipv4: String?
    let ipv6: String?
    let totalDownloaded: UInt64
    let totalUploaded: UInt64
    @ObservedObject var wifiDetails: NetworkWiFiDetailsService

    private let color = MonitorPopoverStyle.color(for: .network)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                NetworkRateCard(title: "下载", value: rate(downloadRate), values: downloadHistory, color: Color(nsColor: .systemBlue))
                NetworkRateCard(title: "上传", value: rate(uploadRate), values: uploadHistory, color: Color(nsColor: .systemPurple))
            }
            MonitorCard("网络信息", color: color) {
                MonitorMetricRow(title: "状态", value: interface == nil ? "未连接" : "已连接")
                MonitorMetricRow(title: "默认接口", value: interface ?? "不可用")
                MonitorMetricRow(title: "IPv4", value: ipv4 ?? "不可用")
                MonitorMetricRow(title: "IPv6", value: ipv6 ?? "不可用")
                MonitorMetricRow(title: "累计下载", value: bytes(totalDownloaded))
                MonitorMetricRow(title: "累计上传", value: bytes(totalUploaded))
            }
            MonitorCard("Wi-Fi", color: color) {
                MonitorMetricRow(title: "SSID", value: wifiDetails.ssid)
                MonitorMetricRow(title: "BSSID", value: wifiDetails.bssid)
                MonitorMetricRow(title: "信号", value: wifiDetails.signal)
                if wifiDetails.status != "可用" {
                    MonitorMetricRow(title: "状态", value: wifiDetails.status)
                }
                Button("读取 Wi-Fi 详情") {
                    wifiDetails.requestDetails(defaultInterfaceName: interface)
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.borderless)
            }
        }
    }

    private func rate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

private struct NetworkRateCard: View {
    let title: String
    let value: String
    let values: [Double]
    let color: Color

    var body: some View {
        MonitorCard(color: color) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.title3).monospacedDigit()
            MonitorTrendGraph(values: values, color: color)
        }
    }
}

struct MonitorModuleSettingsView: View {
    let moduleID: SystemMonitorModuleID
    @ObservedObject private var host = ModuleHost.shared
    @ObservedObject private var metrics = SystemMetricsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("刷新间隔", selection: binding(\.refreshInterval)) {
                Text("1 秒").tag(TimeInterval(1)); Text("2 秒").tag(TimeInterval(2)); Text("5 秒").tag(TimeInterval(5)); Text("10 秒").tag(TimeInterval(10))
            }
            Picker("颜色", selection: binding(\.color)) {
                ForEach(MonitorWidgetColor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if moduleID == .gpu {
                Picker("GPU 设备", selection: deviceBinding) {
                    Text("自动").tag("")
                    ForEach(metrics.current.gpu?.devices ?? []) { device in
                        Text("\(device.model) · \(device.type.rawValue)").tag(device.id)
                    }
                }
                Toggle("显示 GPU 类型", isOn: binding(\.showsItemType))
            }
            Text("菜单栏组件").font(.caption).foregroundStyle(.secondary)
            ForEach(allowedWidgets, id: \.self) { widget in Toggle(widget.rawValue, isOn: widgetBinding(widget)) }
            if !preferences.widgets.isEmpty {
                Text("组件顺序").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(preferences.widgets.enumerated()), id: \.element) { index, widget in
                    HStack {
                        Text(widget.rawValue)
                        Spacer()
                        Button { moveWidget(widget, offset: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button { moveWidget(widget, offset: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == preferences.widgets.count - 1)
                    }
                }
            }
        }
        .font(.system(size: 13))
    }

    private var preferences: MonitorModulePreferences { host.preferences.monitorPreferences(for: moduleID) }
    private var allowedWidgets: [MonitorWidgetKind] {
        switch moduleID {
        case .cpu: [.label, .miniPercentage, .lineChart, .barChart, .pieChart, .gauge]
        case .gpu: [.label, .miniPercentage, .lineChart, .barChart, .gauge]
        case .memory: [.label, .miniPercentage, .lineChart, .barChart, .pieChart, .capacity, .status, .gauge]
        case .disk: [.label, .miniPercentage, .barChart, .pieChart, .capacity, .readWriteSpeed, .throughputChart, .text]
        case .network: [.label, .uploadSpeed, .downloadSpeed, .throughputChart, .connectionStatus, .ipAddress]
        }
    }
    private func binding<Value>(_ keyPath: WritableKeyPath<MonitorModulePreferences, Value>) -> Binding<Value> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { value in var updated = preferences; updated[keyPath: keyPath] = value; host.setMonitorPreferences(updated, for: moduleID) })
    }
    private var deviceBinding: Binding<String> {
        Binding(get: { preferences.selectedItemID ?? "" }, set: { value in var updated = preferences; updated.selectedItemID = value.isEmpty ? nil : value; host.setMonitorPreferences(updated, for: moduleID) })
    }
    private func widgetBinding(_ widget: MonitorWidgetKind) -> Binding<Bool> {
        Binding(get: { preferences.widgets.contains(widget) }, set: { enabled in
            var updated = preferences
            if enabled, !updated.widgets.contains(widget) { updated.widgets.append(widget) }
            if !enabled { updated.widgets.removeAll { $0 == widget } }
            host.setMonitorPreferences(updated, for: moduleID)
        })
    }
    private func moveWidget(_ widget: MonitorWidgetKind, offset: Int) {
        var updated = preferences
        guard let index = updated.widgets.firstIndex(of: widget) else { return }
        let destination = min(max(index + offset, 0), updated.widgets.count - 1)
        guard destination != index else { return }
        updated.widgets.remove(at: index)
        updated.widgets.insert(widget, at: destination)
        host.setMonitorPreferences(updated, for: moduleID)
    }
}
