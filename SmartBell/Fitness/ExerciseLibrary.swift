import Foundation

/// How a set of an exercise can be counted.
enum TrackingMode: String, Codable, CaseIterable, Identifiable {
    case sensor   // SmartBell on the forearm (curls built in; other exercises taught once)
    case camera   // phone camera + Vision body pose
    case manual   // you enter the reps
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sensor: "SmartBell"
        case .camera: "Camera"
        case .manual: "Manual"
        }
    }

    var symbol: String {
        switch self {
        case .sensor: "sensor"
        case .camera: "camera"
        case .manual: "hand.tap"
        }
    }
}

/// A joint angle measured from the camera skeleton (2D, image plane).
enum PoseMetric: String, Codable {
    case forearmFromVertical  // same quantity the SmartBell measures (side view)
    case elbowFlexion         // 0 = arm straight
    case kneeFlexion          // 0 = leg straight
    case armRaise             // 0 = arm down by your side, 90 = horizontal, 180 = overhead

    var label: String {
        switch self {
        case .forearmFromVertical: "Forearm angle"
        case .elbowFlexion: "Elbow bend"
        case .kneeFlexion: "Knee bend"
        case .armRaise: "Arm raise"
        }
    }
}

/// Camera rep counting for one exercise: the rep goes from `restDeg` toward `workDeg` and back.
/// `restDeg` may be larger than `workDeg` (e.g. a press starts bent and straightens).
struct CameraRepConfig: Codable, Equatable {
    var metric: PoseMetric
    var restDeg: Double
    var workDeg: Double
    var setupHint: String
}

enum MuscleGroup: String, Codable, CaseIterable {
    case arms = "Arms", shoulders = "Shoulders", chest = "Chest", back = "Back", legs = "Legs", core = "Core"
}

struct Exercise: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var group: MuscleGroup
    var tracking: [TrackingMode]       // supported, best first
    var camera: CameraRepConfig?
    var usesWeight: Bool = true
    var increment: Double = 2.5        // lb; progression step (kg uses half, rounded to 1)

    static func == (a: Exercise, b: Exercise) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var supportsSensor: Bool { tracking.contains(.sensor) }
    /// Curls work with SmartBell out of the box (the 15 s calibration). Everything else is
    /// taught once: hold the start position, do 3 reps.
    var sensorBuiltIn: Bool { id == "bicep-curl" || id == "hammer-curl" }
    var supportsCamera: Bool { tracking.contains(.camera) && camera != nil }
}

enum ExerciseLibrary {
    static let all: [Exercise] = [
        Exercise(id: "bicep-curl", name: "Bicep curl", group: .arms, tracking: [.sensor, .camera, .manual],
                 camera: CameraRepConfig(metric: .forearmFromVertical, restDeg: 15, workDeg: 125,
                                         setupHint: "Stand side-on to the camera, whole arm in view.")),
        Exercise(id: "hammer-curl", name: "Hammer curl", group: .arms, tracking: [.sensor, .camera, .manual],
                 camera: CameraRepConfig(metric: .forearmFromVertical, restDeg: 15, workDeg: 125,
                                         setupHint: "Stand side-on to the camera, whole arm in view.")),
        Exercise(id: "overhead-triceps", name: "Overhead triceps extension", group: .arms, tracking: [.camera, .sensor, .manual],
                 camera: CameraRepConfig(metric: .elbowFlexion, restDeg: 120, workDeg: 25,
                                         setupHint: "Stand side-on, elbow pointing up.")),
        Exercise(id: "shoulder-press", name: "Shoulder press", group: .shoulders, tracking: [.camera, .sensor, .manual],
                 camera: CameraRepConfig(metric: .elbowFlexion, restDeg: 95, workDeg: 25,
                                         setupHint: "Face the camera, arms and head in view.")),
        Exercise(id: "lateral-raise", name: "Lateral raise", group: .shoulders, tracking: [.camera, .sensor, .manual],
                 camera: CameraRepConfig(metric: .armRaise, restDeg: 15, workDeg: 80,
                                         setupHint: "Face the camera, hips to hands in view."), increment: 2.5),
        Exercise(id: "front-raise", name: "Front raise", group: .shoulders, tracking: [.camera, .sensor, .manual],
                 camera: CameraRepConfig(metric: .armRaise, restDeg: 15, workDeg: 80,
                                         setupHint: "Stand side-on, hips to hands in view.")),
        Exercise(id: "push-up", name: "Push-up", group: .chest, tracking: [.camera, .sensor, .manual],
                 camera: CameraRepConfig(metric: .elbowFlexion, restDeg: 15, workDeg: 80,
                                         setupHint: "Camera at floor level, side-on, whole body in view."),
                 usesWeight: false),
        Exercise(id: "bench-press", name: "Bench press", group: .chest, tracking: [.sensor, .manual], camera: nil, increment: 5),
        Exercise(id: "bent-row", name: "Bent-over row", group: .back, tracking: [.sensor, .manual], camera: nil, increment: 5),
        Exercise(id: "squat", name: "Squat", group: .legs, tracking: [.camera, .sensor, .manual],
                 camera: CameraRepConfig(metric: .kneeFlexion, restDeg: 10, workDeg: 80,
                                         setupHint: "Side-on, whole body in view, phone about 2 m away."), increment: 5),
        Exercise(id: "lunge", name: "Lunge", group: .legs, tracking: [.camera, .sensor, .manual],
                 camera: CameraRepConfig(metric: .kneeFlexion, restDeg: 10, workDeg: 75,
                                         setupHint: "Side-on, whole body in view."), increment: 5),
        Exercise(id: "deadlift", name: "Romanian deadlift", group: .legs, tracking: [.sensor, .manual], camera: nil, increment: 5),
        Exercise(id: "crunch", name: "Crunch", group: .core, tracking: [.sensor, .manual], camera: nil, usesWeight: false),
    ]

    static func exercise(_ id: String) -> Exercise? { all.first { $0.id == id } }
    static var cameraExercises: [Exercise] { all.filter(\.supportsCamera) }

    /// Built-in workouts. Users can copy and edit them or make their own.
    static let templates: [WorkoutTemplate] = [
        WorkoutTemplate(id: "builtin-arms", name: "Arm day", builtIn: true, items: [
            PlannedExercise(exerciseId: "bicep-curl", sets: 3, reps: 10, weight: 15, restSeconds: 90),
            PlannedExercise(exerciseId: "hammer-curl", sets: 3, reps: 10, weight: 15, restSeconds: 90),
            PlannedExercise(exerciseId: "overhead-triceps", sets: 3, reps: 12, weight: 15, restSeconds: 75),
        ]),
        WorkoutTemplate(id: "builtin-upper", name: "Upper body", builtIn: true, items: [
            PlannedExercise(exerciseId: "shoulder-press", sets: 3, reps: 10, weight: 20, restSeconds: 120),
            PlannedExercise(exerciseId: "push-up", sets: 3, reps: 12, weight: 0, restSeconds: 90),
            PlannedExercise(exerciseId: "lateral-raise", sets: 3, reps: 12, weight: 10, restSeconds: 60),
            PlannedExercise(exerciseId: "bicep-curl", sets: 3, reps: 10, weight: 15, restSeconds: 90),
        ]),
        WorkoutTemplate(id: "builtin-full", name: "Full body starter", builtIn: true, items: [
            PlannedExercise(exerciseId: "squat", sets: 3, reps: 12, weight: 0, restSeconds: 90),
            PlannedExercise(exerciseId: "push-up", sets: 3, reps: 10, weight: 0, restSeconds: 90),
            PlannedExercise(exerciseId: "bicep-curl", sets: 2, reps: 12, weight: 15, restSeconds: 60),
            PlannedExercise(exerciseId: "lunge", sets: 2, reps: 10, weight: 0, restSeconds: 60),
        ]),
        WorkoutTemplate(id: "builtin-rehab-elbow", name: "Elbow mobility (rehab)", builtIn: true, items: [
            PlannedExercise(exerciseId: "bicep-curl", sets: 3, reps: 15, weight: 2.5, restSeconds: 60),
            PlannedExercise(exerciseId: "hammer-curl", sets: 2, reps: 15, weight: 2.5, restSeconds: 60),
        ]),
    ]
}
