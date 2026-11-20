# Notes for agents and teammates

- The motion algorithm exists twice: `SmartBell/Motion/*.swift` (app) and `tools/smartbell_motion.py` (reference, testable on a laptop). Keep them in sync: change Python first, run `python3 tools/evaluate.py --seeds 20`, then port the change to Swift.
- Never reintroduce double integration of acceleration. Rep state comes from the gravity-referenced forearm angle; heading is re-anchored every rep.
- All thresholds live in `MotionModels.swift` (`MotionParams`, `Calibration`, `FormIssue`) and `RepDetector.analyse`.
- The Xcode project lists files explicitly. After adding or moving a Swift file, run `python3 tools/gen_xcodeproj.py` (or add it in Xcode).
- Demo data must stay labelled as demo in the UI.
