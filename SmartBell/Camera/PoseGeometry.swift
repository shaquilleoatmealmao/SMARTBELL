//
//  PoseGeometry.swift
//  SmartBell — Camera
//
//  Joint names and 2D angle math for camera pose tracking. PoseFrame.angle(_:) turns a
//  detected skeleton into the one angle an exercise is counted on (PoseMetric, defined
//  in ExerciseLibrary). Angles are 2D (in the image plane), which is why each camera
//  exercise tells the user to film side-on or facing.
//

import Foundation
import CoreGraphics
import Vision

/// The body joints the app uses from Vision's 19-point skeleton.
enum Joint: String, CaseIterable, Hashable {
    case nose, neck, root
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle

    /// The matching Vision joint key.
    var visionName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: .nose
        case .neck: .neck
        case .root: .root
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        }
    }

    /// Lines drawn for the skeleton overlay.
    static let bones: [(Joint, Joint)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist), (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip), (.leftHip, .rightHip), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle), (.neck, .nose),
    ]
}

/// One detected skeleton. Points are normalised 0...1 with the origin at the TOP-left of the image.
struct PoseFrame {
    var points: [Joint: CGPoint]
    var confidence: [Joint: Float]
    var imageSize: CGSize
    var time: TimeInterval

    static let minConfidence: Float = 0.3   // ignore joints Vision is less sure about than this

    /// Normalised point for a joint, or nil if missing / low confidence.
    func point(_ j: Joint) -> CGPoint? {
        guard let p = points[j], (confidence[j] ?? 0) >= PoseFrame.minConfidence else { return nil }
        return p
    }

    /// Point in pixels, so angles aren't distorted by the image's aspect ratio.
    private func px(_ j: Joint) -> CGPoint? {
        point(j).map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
    }

    /// Measure a metric on whichever side of the body is seen more confidently.
    func angle(_ metric: PoseMetric) -> Double? {
        let sides: [(shoulder: Joint, elbow: Joint, wrist: Joint, hip: Joint, knee: Joint, ankle: Joint)] = [
            (.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle),
            (.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle),
        ]
        var best: (value: Double, conf: Float)?
        for s in sides {
            let joints: [Joint]
            switch metric {
            case .forearmFromVertical: joints = [s.elbow, s.wrist]
            case .elbowFlexion: joints = [s.shoulder, s.elbow, s.wrist]
            case .kneeFlexion: joints = [s.hip, s.knee, s.ankle]
            case .armRaise: joints = [s.hip, s.shoulder, s.elbow]
            }
            let pts = joints.compactMap { px($0) }
            guard pts.count == joints.count else { continue }
            let conf = joints.map { confidence[$0] ?? 0 }.min() ?? 0
            let value: Double
            switch metric {
            case .forearmFromVertical:
                // angle between elbow->wrist and straight down (image y grows downward)
                value = PoseFrame.angle(between: CGVector(dx: pts[1].x - pts[0].x, dy: pts[1].y - pts[0].y),
                                        and: CGVector(dx: 0, dy: 1))
            case .elbowFlexion, .kneeFlexion:
                // Flexion = 180° − interior angle, so a straight limb reads 0°.
                value = 180 - PoseFrame.interior(pts[0], pts[1], pts[2])
            case .armRaise:
                // Angle at the shoulder between torso (hip) and upper arm (elbow): 0° = arm down.
                value = PoseFrame.interior(pts[0], pts[1], pts[2])
            }
            // Keep the side whose weakest joint is the most confident.
            if best == nil || conf > best!.conf { best = (value, conf) }
        }
        return best?.value
    }

    /// Interior angle at b, in degrees.
    static func interior(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        angle(between: CGVector(dx: a.x - b.x, dy: a.y - b.y), and: CGVector(dx: c.x - b.x, dy: c.y - b.y))
    }

    /// Unsigned angle between two vectors, degrees (0...180): acos(u·v / |u||v|).
    static func angle(between u: CGVector, and v: CGVector) -> Double {
        let nu = hypot(u.dx, u.dy), nv = hypot(v.dx, v.dy)
        guard nu > 1e-6, nv > 1e-6 else { return 0 }
        let c = (u.dx * v.dx + u.dy * v.dy) / (nu * nv)
        return acos(max(-1, min(1, Double(c)))) * 180 / .pi
    }
}
