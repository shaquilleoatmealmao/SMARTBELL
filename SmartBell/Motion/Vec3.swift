import Foundation

/// Small 3D vector type. All motion math is in Double.
struct Vec3: Codable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    static let zero = Vec3(0, 0, 0)

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var norm: Double { sqrt(dot(self)) }
    var normalized: Vec3 {
        let n = norm
        return n < 1e-12 ? self : self * (1.0 / n)
    }
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    /// Rotate by a rotation vector (axis * angle in radians), Rodrigues' formula.
    func rotated(by rv: Vec3) -> Vec3 {
        let angle = rv.norm
        if angle < 1e-12 { return self }
        let k = rv * (1.0 / angle)
        let c = cos(angle), s = sin(angle)
        return self * c + k.cross(self) * s + k * (k.dot(self) * (1.0 - c))
    }

    /// Component of self perpendicular to unit vector n.
    func removingComponent(along n: Vec3) -> Vec3 { self - n * dot(n) }
}

/// 3x3 rotation matrix (rows). Only used by the demo sensor.
struct Mat3 {
    var r0: Vec3, r1: Vec3, r2: Vec3

    static let identity = Mat3(r0: Vec3(1, 0, 0), r1: Vec3(0, 1, 0), r2: Vec3(0, 0, 1))

    init(r0: Vec3, r1: Vec3, r2: Vec3) { self.r0 = r0; self.r1 = r1; self.r2 = r2 }

    /// Rotation about a unit axis by angle (rad).
    init(axis: Vec3, angle: Double) {
        let k = axis.normalized
        let c = cos(angle), s = sin(angle), t = 1 - c
        r0 = Vec3(t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y)
        r1 = Vec3(t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x)
        r2 = Vec3(t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c)
    }

    var transposed: Mat3 {
        Mat3(r0: Vec3(r0.x, r1.x, r2.x), r1: Vec3(r0.y, r1.y, r2.y), r2: Vec3(r0.z, r1.z, r2.z))
    }

    static func * (m: Mat3, v: Vec3) -> Vec3 { Vec3(m.r0.dot(v), m.r1.dot(v), m.r2.dot(v)) }

    static func * (a: Mat3, b: Mat3) -> Mat3 {
        let bt = b.transposed
        return Mat3(r0: Vec3(a.r0.dot(bt.r0), a.r0.dot(bt.r1), a.r0.dot(bt.r2)),
                    r1: Vec3(a.r1.dot(bt.r0), a.r1.dot(bt.r1), a.r1.dot(bt.r2)),
                    r2: Vec3(a.r2.dot(bt.r0), a.r2.dot(bt.r1), a.r2.dot(bt.r2)))
    }

    /// Rotation vector (axis * angle) of this rotation matrix (log map).
    var rotationVector: Vec3 {
        let trace = r0.x + r1.y + r2.z
        let cosA = max(-1.0, min(1.0, (trace - 1) / 2))
        let angle = acos(cosA)
        let v = Vec3(r2.y - r1.z, r0.z - r2.x, r1.x - r0.y)
        if angle < 1e-9 { return v * 0.5 }
        let s = sin(angle)
        if abs(s) < 1e-9 { return .zero } // 180 degrees: not reachable between 10 ms samples
        return v * (angle / (2 * s))
    }
}

let degPerRad = 180.0 / Double.pi
let radPerDeg = Double.pi / 180.0
