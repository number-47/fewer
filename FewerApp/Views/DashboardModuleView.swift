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

    var body: some View {
        MenuBarPopoverChrome(
            title: moduleID.title,
            systemImage: moduleID.systemImage,
            openSettings: openSettings
        ) {
            MonitorModuleContent(moduleID: moduleID)
        }
    }
}

/// 监控详情内容可嵌入工具箱；采样可见性随该内容的出现和消失更新。
struct MonitorModuleContent: View {
    let moduleID: SystemMonitorModuleID
    @ObservedObject private var metrics = SystemMetricsService.shared
    @StateObject private var wifiDetails = NetworkWiFiDetailsService()
    @State private var showsWiFiDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                row("下载", rate(metrics.current.networkInBytesPerSecond))
                row("上传", rate(metrics.current.networkOutBytesPerSecond))
                row("状态", metrics.defaultNetworkInterface == nil ? "未连接" : "已连接")
                row("默认接口", metrics.defaultNetworkInterface ?? "不可用")
                row("IPv4", metrics.localIPv4Address ?? "不可用")
                row("IPv6", metrics.localIPv6Address ?? "不可用")
                row("累计下载", ByteCountFormatter.string(fromByteCount: Int64(metrics.current.networkInBytes), countStyle: .file))
                row("累计上传", ByteCountFormatter.string(fromByteCount: Int64(metrics.current.networkOutBytes), countStyle: .file))
                DisclosureGroup("Wi-Fi 详情", isExpanded: Binding(
                    get: { showsWiFiDetails },
                    set: { isExpanded in
                        showsWiFiDetails = isExpanded
                        if isExpanded {
                            wifiDetails.requestDetails(defaultInterfaceName: metrics.defaultNetworkInterface)
                        }
                    }
                )) {
                    row("SSID", wifiDetails.ssid)
                    row("BSSID", wifiDetails.bssid)
                    row("信号", wifiDetails.signal)
                    if wifiDetails.status != "可用" { row("状态", wifiDetails.status) }
                }
            }
            if moduleID == .network {
                Text("详细采样将在对应监控模块启用后显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
            .padding(14)
        }
        .onAppear { metrics.setModuleVisible(moduleID, isVisible: true) }
        .onDisappear { metrics.setModuleVisible(moduleID, isVisible: false) }
    }

    private var gpuHistory: [Double] {
        guard let deviceID = metrics.current.gpu?.selectedDevice?.id else { return [] }
        return metrics.history.compactMap { $0.gpu?.device(id: deviceID)?.utilization }
    }
    private func row(_ name: String, _ value: String) -> some View { HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() } }
    private func percentage(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func rate(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s" }
}

private extension SystemMonitorModuleID {
    var title: String {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "内存"; case .disk: "磁盘"; case .network: "网络" }
    }

    var systemImage: String {
        switch self { case .cpu: "cpu"; case .gpu, .memory: "memorychip"; case .disk: "internaldrive"; case .network: "network" }
    }
}

private struct DiskDetailsView: View {
    let snapshot: DiskSnapshot?
    let history: [DiskSnapshot]

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(snapshot.volumeName).font(.title3).lineLimit(1)
                        Spacer()
                        Text(percentage(snapshot.usageRatio)).font(.title3).monospacedDigit()
                    }
                    Text("\(bytes(snapshot.usedBytes)) / \(bytes(snapshot.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    DiskHistoryGraph(values: history.map(\.usageRatio))
                    detail("可用", bytes(snapshot.availableBytes))
                    detail("文件系统", snapshot.fileSystem ?? "不可用")
                    detail("连接", snapshot.connectionType ?? "不可用")
                    detail("设备", snapshot.deviceName ?? "不可用")
                    detail("读取", rate(snapshot.readBytesPerSecond))
                    detail("写入", rate(snapshot.writeBytesPerSecond))
                    detail("累计读取", bytes(snapshot.readBytes))
                    detail("累计写入", bytes(snapshot.writeBytes))
                    Divider()
                    Text("SMART").font(.caption).foregroundStyle(.secondary)
                    smartDetails(snapshot.smart)
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
            detail("健康度", smart.health ?? "不可用")
            detail("温度", smart.temperatureCelsius.map { String(format: "%.0f℃", $0) } ?? "不可用")
            detail("寿命", smart.lifeRemainingPercent.map { String(format: "%.0f%%", $0) } ?? "不可用")
            detail("警告", smart.warning ?? "不可用")
            detail("通电时间", smart.powerOnHours.map { "\($0) 小时" } ?? "不可用")
        } else {
            detail("状态", "不可用")
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit().lineLimit(1) }
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

private struct DiskHistoryGraph: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            if values.count > 1 {
                let visible = Array(values.suffix(40))
                Path { path in
                    for (index, value) in visible.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(visible.count - 1)
                        let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            } else {
                Text("暂无历史").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 48)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct MemoryDetailsView: View {
    let snapshot: MemorySnapshot?
    let history: [Double]

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("已用").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(bytes(snapshot.usedBytes)) / \(bytes(snapshot.totalBytes))")
                            .font(.title3).monospacedDigit()
                    }
                    MemoryHistoryGraph(values: history)
                    detail("使用率", percentage(snapshot.usageRatio))
                    detail("App", bytes(snapshot.appBytes))
                    detail("活跃", bytes(snapshot.activeBytes))
                    detail("Wired", bytes(snapshot.wiredBytes))
                    detail("Compressed", bytes(snapshot.compressedBytes))
                    detail("可用", bytes(snapshot.freeBytes))
                    detail("Swap", swap(snapshot.swap))
                    detail("压力", snapshot.pressure?.level.rawValue ?? "不可用")
                }
            } else {
                ContentUnavailableView("内存数据不可用", systemImage: "memorychip", description: Text("系统没有返回可读取的 Mach VM 内存统计。"))
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func swap(_ value: MemorySwapSnapshot?) -> String {
        guard let value else { return "不可用" }
        return "\(bytes(value.usedBytes)) / \(bytes(value.totalBytes))"
    }
}

private struct MemoryHistoryGraph: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            if values.count > 1 {
                let visible = Array(values.suffix(40))
                Path { path in
                    for (index, value) in visible.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(visible.count - 1)
                        let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            } else {
                Text("暂无历史").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 48)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct GPUDetailsView: View {
    let snapshot: GPUSnapshot?
    let history: [Double]

    var body: some View {
        Group {
            if let snapshot, let gpu = snapshot.selectedDevice {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("总使用率").foregroundStyle(.secondary)
                        Spacer()
                        Text(percentage(gpu.utilization)).font(.title2).monospacedDigit()
                    }
                    GPUHistoryGraph(values: history)
                    HStack(spacing: 12) {
                        usage("Render", gpu.renderUtilization)
                        usage("Tiler", gpu.tilerUtilization)
                        usage("ANE", gpu.aneUtilization)
                    }
                    detail("设备", snapshot.selectedAutomatically ? "自动 · \(gpu.model)" : "已选 · \(gpu.model)")
                    detail("类型", gpu.type.rawValue)
                    detail("核心", gpu.coreCount.map(String.init) ?? "不可用")
                    detail("FPS", gpu.framesPerSecond.map { String(format: "%.0f", $0) } ?? "不可用")
                    detail("状态", gpu.isActive ? "可用" : "已关闭")
                    if snapshot.devices.count > 1 {
                        detail("已发现 GPU", "\(snapshot.devices.count)")
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

    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
    }

    private func percentage(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "不可用"
    }
}

private struct GPUHistoryGraph: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            if values.count > 1 {
                let visible = Array(values.suffix(40))
                Path { path in
                    for (index, value) in visible.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(visible.count - 1)
                        let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            } else {
                Text("暂无历史").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 48)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct CPUDetailsView: View {
    let snapshot: CPUSnapshot?
    let history: [Double]

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("总使用率").foregroundStyle(.secondary)
                        Spacer()
                        Text(percentage(snapshot.total)).font(.title2).monospacedDigit()
                    }
                    CPUHistoryGraph(values: history)
                    HStack(spacing: 12) {
                        usage("用户", snapshot.user)
                        usage("系统", snapshot.system)
                        usage("空闲", snapshot.idle)
                    }
                    detail("负载", loadAverage(snapshot.loadAverage))
                    detail("运行时间", snapshot.uptime.map(uptime) ?? "不可用")
                    detail("频率", snapshot.frequencyHz.map(frequency) ?? "不可用")
                    detail("温度", snapshot.temperatureCelsius.map { String(format: "%.0f℃", $0) } ?? "不可用")
                    coreDetails(snapshot.cores)
                    clusterDetails(snapshot.clusters)
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

    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
    }

    @ViewBuilder
    private func coreDetails(_ cores: [CPUCoreSnapshot]) -> some View {
        if cores.isEmpty {
            detail("核心", "不可用")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("核心").foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(cores.count, 4)), spacing: 4) {
                    ForEach(cores) { core in
                        Text("\(core.id + 1) · \(percentage(core.total))")
                            .font(.caption2).monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clusterDetails(_ clusters: [CPUClusterSnapshot]) -> some View {
        if clusters.isEmpty {
            detail("性能集群", "不可用")
        } else {
            ForEach(clusters) { cluster in
                detail(cluster.name, "\(cluster.physicalCoreCount) 物理 / \(cluster.logicalCoreCount) 逻辑核心")
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

private struct CPUHistoryGraph: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            if values.count > 1 {
                Path { path in
                    let visible = Array(values.suffix(40))
                    for (index, value) in visible.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(visible.count - 1)
                        let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 1)))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            } else {
                Text("暂无历史").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 48)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
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
