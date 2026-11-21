import SwiftUI

@main
struct SmartBellApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TrainView()
                .tabItem { Label("Train", systemImage: "dumbbell") }
                .tag(0)
            CameraView(camera: model.camera, lab: model.lab)
                .tabItem { Label("Camera", systemImage: "figure.strengthtraining.traditional") }
                .tag(1)
            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(2)
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
                .tag(3)
            DeviceView()
                .tabItem { Label("Device", systemImage: "sensor") }
                .tag(4)
        }
        .fullScreenCover(isPresented: Binding(get: { model.workout != nil },
                                              set: { if !$0 { model.closeWorkout() } })) {
            if let w = model.workout {
                WorkoutPlayerView(workout: w, camera: model.camera)
                    .environmentObject(model)
            }
        }
        // (during a workout these two sheets are shown by the workout screen instead)
        .sheet(isPresented: Binding(get: { model.calibrationStep != nil && model.workout == nil },
                                    set: { if !$0 { model.dismissCalibration() } })) {
            CalibrationView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { model.teachStep != nil && model.workout == nil },
                                    set: { if !$0 { model.dismissTeaching() } })) {
            TeachView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
    }
}
