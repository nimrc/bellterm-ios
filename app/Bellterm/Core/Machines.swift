import Foundation

/// An SSH machine Herdr on a host saved with `herdr machine add`.
struct Machine: Decodable, Equatable, Sendable {
    var label: String
    var target: String
    var session: String

    /// What `listMachines` returns; the core already dropped disabled machines.
    static func parse(_ json: String) throws -> [Machine] {
        try JSONDecoder().decode([Machine].self, from: Data(json.utf8)).map { machine in
            var machine = machine
            if machine.label.trimmingCharacters(in: .whitespaces).isEmpty { machine.label = machine.target }
            if machine.session.isEmpty { machine.session = "default" }
            return machine
        }
    }
}
