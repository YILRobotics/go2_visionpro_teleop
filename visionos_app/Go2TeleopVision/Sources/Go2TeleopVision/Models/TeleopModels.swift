import Foundation
import simd
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

struct HandSample: Sendable {
    let timestamp: TimeInterval
    let rightWristPosition: SIMD3<Float>
    let rightWristRoll: Float
    let pinchDistance: Float
    let isTracked: Bool

    static let invalid = HandSample(
        timestamp: Date().timeIntervalSince1970,
        rightWristPosition: SIMD3<Float>(repeating: 0),
        rightWristRoll: 0,
        pinchDistance: .greatestFiniteMagnitude,
        isTracked: false
    )

    var pinchActive: Bool {
        isTracked && pinchDistance <= 0.03
    }
}

struct WristPositionPayload: Codable, Sendable {
    let x: Float
    let y: Float
    let z: Float
}

struct TeleopOutboundPacket: Codable, Sendable {
    let type: String
    let timestamp: TimeInterval
    let rightWrist: WristPositionPayload
    let rightWristRoll: Float
    let rightPinchDistance: Float
    let rightPinchActive: Bool

    init(sample: HandSample) {
        self.type = "hand_tracking"
        self.timestamp = sample.timestamp
        self.rightWrist = WristPositionPayload(
            x: sample.rightWristPosition.x,
            y: sample.rightWristPosition.y,
            z: sample.rightWristPosition.z
        )
        self.rightWristRoll = sample.rightWristRoll
        self.rightPinchDistance = sample.pinchDistance
        self.rightPinchActive = sample.pinchActive
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self = Image(uiImage: platformImage)
        #elseif canImport(AppKit)
        self = Image(nsImage: platformImage)
        #endif
    }
}

func decodePlatformImage(from data: Data) -> PlatformImage? {
    #if canImport(UIKit)
    return UIImage(data: data)
    #elseif canImport(AppKit)
    return NSImage(data: data)
    #endif
}
