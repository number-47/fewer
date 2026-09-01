import CoreLocation
import CoreWLAN
import Foundation

@MainActor
final class NetworkWiFiDetailsService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var ssid = "不可用"
    @Published private(set) var bssid = "不可用"
    @Published private(set) var signal = "不可用"
    @Published private(set) var status = "未请求"

    private let locationManager = CLLocationManager()
    private var requestedInterfaceName: String?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func requestDetails(defaultInterfaceName: String?) {
        requestedInterfaceName = defaultInterfaceName
        guard CLLocationManager.locationServicesEnabled() else {
            setUnavailable(status: "定位服务不可用")
            return
        }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            loadDetails()
        case .notDetermined:
            status = "正在请求定位权限"
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            setUnavailable(status: "定位权限未授予")
        @unknown default:
            setUnavailable(status: "定位权限不可用")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            loadDetails()
        case .notDetermined:
            break
        case .denied, .restricted:
            setUnavailable(status: "定位权限未授予")
        @unknown default:
            setUnavailable(status: "定位权限不可用")
        }
    }

    private func loadDetails() {
        let client = CWWiFiClient.shared()
        let interface = requestedInterfaceName.flatMap { client.interface(withName: $0) } ?? client.interface()
        guard let interface else {
            setUnavailable(status: "Wi-Fi 不可用")
            return
        }
        ssid = interface.ssid() ?? "不可用"
        bssid = interface.bssid() ?? "不可用"
        let value = interface.rssiValue()
        signal = value == 0 ? "不可用" : "\(value) dBm"
        status = ssid == "不可用" ? "Wi-Fi 信息不可用" : "可用"
    }

    private func setUnavailable(status: String) {
        ssid = "不可用"
        bssid = "不可用"
        signal = "不可用"
        self.status = status
    }
}
