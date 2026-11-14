import Network

/// Only route capabilities/types, never addresses, interface names or SSIDs.
struct NetworkSignature: Equatable, Sendable {
    var satisfied: Bool
    var interfaces: Set<String>
    var ipv4: Bool
    var ipv6: Bool
    var expensive: Bool
    var constrained: Bool
    var status: String = "satisfied"

    init(satisfied: Bool, interfaces: Set<String> = [], ipv4: Bool = false, ipv6: Bool = false,
         expensive: Bool = false, constrained: Bool = false, status: String = "satisfied") {
        self.satisfied = satisfied
        self.interfaces = interfaces
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.expensive = expensive
        self.constrained = constrained
        self.status = status
    }

    init(_ path: NWPath) {
        let types: [(NWInterface.InterfaceType, String)] = [(.wifi, "wifi"), (.cellular, "cellular"),
            (.wiredEthernet, "wired"), (.loopback, "loopback"), (.other, "other")]
        self.init(satisfied: path.status == .satisfied,
                  interfaces: Set(types.filter { path.usesInterfaceType($0.0) }.map(\.1)),
                  ipv4: path.supportsIPv4, ipv6: path.supportsIPv6,
                  expensive: path.isExpensive, constrained: path.isConstrained,
                  status: path.status == .satisfied ? "satisfied" : path.status == .requiresConnection ? "requiresConnection" : "unsatisfied")
    }
}
