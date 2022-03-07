import Network

internal protocol ConnectivityListenerDelegate: AnyObject {

    func connectivityListener(_: ConnectivityListener, didUpdate hasConnectivity: Bool)
    // network remains to have connectivity but path changed
    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath)
}

internal extension ConnectivityListenerDelegate {
    func connectivityListener(_: ConnectivityListener, didUpdate hasConnectivity: Bool) {}
    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath) {}
}

internal class ConnectivityListener: MulticastDelegate<ConnectivityListenerDelegate> {

    static let shared = ConnectivityListener()

    public private(set) var hasConnectivity: Bool? {
        didSet {
            guard let newValue = hasConnectivity, oldValue != newValue else { return }
            notify { $0.connectivityListener(self, didUpdate: newValue) }
        }
    }

    public private(set) var ipv4: String?
    public private(set) var path: NWPath?

    private let queue = DispatchQueue(label: "LiveKitSDK.connectivityListener",
                                      qos: .userInitiated)
    private let monitor = NWPathMonitor()

    private init() {
        super.init(qos: .userInitiated)

        log("initial path: \(monitor.currentPath), has: \(monitor.currentPath.hasConnectivity())")

        monitor.pathUpdateHandler = { path in
            DispatchQueue.sdk.async { self.set(path: path) }
        }

        monitor.start(queue: queue)
    }
}

private extension ConnectivityListener {

    func set(path newValue: NWPath, shouldNotify: Bool = false) {

        log("NWPathDidUpdate status: \(newValue.status), interfaces: \(newValue.availableInterfaces.map({ "\(String(describing: $0.type))-\(String(describing: $0.index))" })), gateways: \(newValue.gateways), activeIp: \(String(describing: newValue.availableInterfaces.first?.ipv4))")

        // check if different path
        guard newValue != self.path else { return }

        // keep old values
        let oldValue = self.path
        let oldIpValue = self.ipv4

        // update new values
        let newIpValue = newValue.availableInterfaces.first?.ipv4
        self.path = newValue
        self.ipv4 = newIpValue
        self.hasConnectivity = newValue.hasConnectivity()

        // continue if old value exists
        guard let oldValue = oldValue else { return }

        // continue if was network switch (old and new have connectivity)
        guard oldValue.hasConnectivity(), newValue.hasConnectivity() else { return }

        let oldInterface = oldValue.availableInterfaces.first
        let newInterface = newValue.availableInterfaces.first

        if (oldInterface != newInterface) // active interface changed
            || (oldIpValue != newIpValue) // or, same interface but ip changed (detect wifi network switch)
        {
            notify { $0.connectivityListener(self, didSwitch: newValue) }
        }
    }
}

internal extension NWPath {

    func hasConnectivity() -> Bool {
        if case .satisfied = status { return true }
        return false
    }
}

internal extension NWInterface {

    func address(family: Int32) -> String? {

        var address: String?

        // get list of all interfaces on the local machine:
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }

        // for each interface ...
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee

            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(family) {
                // Check interface name:
                if name == String(cString: interface.ifa_name) {
                    // Convert interface address to a human readable string:
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        freeifaddrs(ifaddr)

        return address
    }

    var ipv4: String? { self.address(family: AF_INET) }
    var ipv6: String? { self.address(family: AF_INET6) }
}
