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
            WorkoutView()
                .tabItem { Label("Workout", systemImage: "dumbbell") }
                .tag(0)
            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar.xaxis") }
                .tag(1)
            DeviceView()
                .tabItem { Label("Device", systemImage: "sensor") }
                .tag(2)
        }
        .sheet(isPresented: Binding(get: { model.calibrationStep != nil },
                                    set: { if !$0 { model.dismissCalibration() } })) {
            CalibrationView()
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
    }
}
