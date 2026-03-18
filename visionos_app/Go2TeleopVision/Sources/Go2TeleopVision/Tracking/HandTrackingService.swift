import Foundation
import simd

#if os(visionOS)
import ARKit
import QuartzCore
#endif

@MainActor
final class HandTrackingService: ObservableObject {
    @Published private(set) var latestSample: HandSample = .invalid
    @Published private(set) var isSupported: Bool = false
    @Published private(set) var stateText: String = "Stopped"

    private var pollingTask: Task<Void, Never>?

    #if os(visionOS)
    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    #endif

    func start() {
        stop()

        #if os(visionOS)
        guard HandTrackingProvider.isSupported else {
            isSupported = false
            stateText = "Hand tracking not supported on this device."
            latestSample = .invalid
            return
        }

        isSupported = true
        stateText = "Starting hand tracking..."
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.run([self.handTracking])
                self.stateText = "Hand tracking active"
                await self.pollHandData()
            } catch {
                self.latestSample = .invalid
                self.stateText = "ARKit error: \(error.localizedDescription)"
            }
        }
        #else
        isSupported = false
        stateText = "Hand tracking runs on visionOS only."
        latestSample = .invalid
        #endif
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        latestSample = .invalid
        if isSupported {
            stateText = "Stopped"
        }
    }

    #if os(visionOS)
    private func pollHandData() async {
        while !Task.isCancelled {
            guard handTracking.state == .running else {
                latestSample = .invalid
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }

            let anchors = handTracking.handAnchors(at: CACurrentMediaTime() + 0.02)
            guard let rightAnchor = anchors.rightHand,
                  rightAnchor.isTracked,
                  let skeleton = rightAnchor.handSkeleton else {
                latestSample = .invalid
                try? await Task.sleep(for: .milliseconds(16))
                continue
            }

            let wristTransform = rightAnchor.originFromAnchorTransform
            let thumbTipTransform = wristTransform * skeleton.joint(.thumbTip).anchorFromJointTransform
            let indexTipTransform = wristTransform * skeleton.joint(.indexFingerTip).anchorFromJointTransform

            let thumbPos = thumbTipTransform.translation
            let indexPos = indexTipTransform.translation
            let pinchDistance = simd_distance(thumbPos, indexPos)

            latestSample = HandSample(
                timestamp: Date().timeIntervalSince1970,
                rightWristPosition: wristTransform.translation,
                rightWristRoll: wristTransform.rollRadians,
                pinchDistance: pinchDistance,
                isTracked: true
            )

            try? await Task.sleep(for: .milliseconds(16))
        }
    }
    #endif
}

#if os(visionOS)
private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    // Approximate roll around local X axis.
    var rollRadians: Float {
        atan2f(columns.1.z, columns.2.z)
    }
}
#endif
