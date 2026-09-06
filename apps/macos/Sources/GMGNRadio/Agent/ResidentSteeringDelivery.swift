import Foundation

/// An uncertain provider write must not be automatically replayed in a persistent session.
enum ResidentSteeringDelivery: String, Codable, Sendable {
    case delivered, notDelivered, unknown
}
