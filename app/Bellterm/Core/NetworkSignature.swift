import Network

/// Only what can change reachability: the path status, the physical interface
/// types in use, IP support and an opaque fingerprint of the local route.
/// Never addresses, interface names or SSIDs.
struct NetworkSignature: Equatable, Sendable {
    private static let physical: Set<String> = ["wifi", "cellular", "wired"]

    var satisfied: Bool
    var interfaces: Set<String>
    var ipv4: Bool
    var ipv6: Bool
    /// Kept for callers/tests, but low-data mode and metering do not change
    /// whether the route is reachable, so they do not make a new signature.
    var expensive: Bool
    var constrained: Bool
    var status: String = "satisfied"
    /// Opaque local-route fingerprint, used to notice a Wi-Fi access-point
    /// switch. It is only compared, never logged or shown.
    var endpoint: Int?
    /// A tunnel (VPN) hides the physical route; its endpoint changes say
    /// nothing about whether the underlying link changed.
    var tunnel: Bool

    init(satisfied: Bool, interfaces: Set<String> = [], ipv4: Bool = false, ipv6: Bool = false,
         expensive: Bool = false, constrained: Bool = false, status: String = "satisfied",
         endpoint: Int? = nil, tunnel: Bool = false) {
        self.satisfied = satisfied
        self.interfaces = interfaces.intersection(Self.physical)
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.expensive = expensive
        self.constrained = constrained
        self.status = status
        self.endpoint = endpoint
        self.tunnel = tunnel
    }

    init(_ path: NWPath) {
        let types: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"),
        ]
        let tunnel = path.usesInterfaceType(.other)
        self.init(satisfied: path.status == .satisfied,
                  interfaces: Set(types.filter { path.usesInterfaceType($0.0) }.map(\.1)),
                  ipv4: path.supportsIPv4, ipv6: path.supportsIPv6,
                  expensive: path.isExpensive, constrained: path.isConstrained,
                  status: path.status == .satisfied ? "satisfied" : path.status == .requiresConnection ? "requiresConnection" : "unsatisfied",
                  endpoint: tunnel ? nil : Self.endpoint(path),
                  tunnel: tunnel)
    }

    /// The local endpoint or gateway, hashed so no address is retained. A
    /// packet tunnel has no stable physical route to compare.
    private static func endpoint(_ path: NWPath) -> Int? {
        if let local = path.localEndpoint {
            return String(describing: local).hashValue
        }
        let gateways = path.gateways.map { String(describing: $0) }.sorted()
        return gateways.isEmpty ? nil : gateways.joined(separator: "|").hashValue
    }

    /// IP support is logged but not compared: an IPv6 flag can appear on the
    /// same link and must not reset backoff. Expensive/constrained (low-data
    /// mode) likewise do not change reachability. A tunnel coming up or going
    /// down is always a real change; only compare the local route while both
    /// sides are untunneled, because a tunnel hides the underlying endpoint.
    static func == (lhs: NetworkSignature, rhs: NetworkSignature) -> Bool {
        lhs.satisfied == rhs.satisfied
            && lhs.interfaces == rhs.interfaces
            && lhs.status == rhs.status
            && lhs.tunnel == rhs.tunnel
            && (lhs.tunnel || lhs.endpoint == rhs.endpoint)
    }
}
