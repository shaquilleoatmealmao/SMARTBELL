# SmartBell v2

iPhone fitness tracker built around the SmartBell forearm sensor (ESP32 + BMX160) and the phone camera. It runs guided workouts hands-free: it counts reps, ends sets when you pause, times your rest, coaches form by voice and vibration, suggests next session's weights, and graphs your progress.

This is a rewrite of the app in `ez-codes-07/smart-bell`. The firmware is unchanged. The motion code is new: it no longer integrates acceleration, which is why the old rep counter drifted. See [docs/ALGORITHM.md](docs/ALGORITHM.md).

## What it does

**Tracking**
- **SmartBell (curls):** counts reps from the forearm's angle to gravity. That angle can't drift, so counting doesn't depend on speed and doesn't degrade over a set. After every rep you get a form score and one spoken cue covering swinging, elbow drift, partial range, tempo, wrist twist or a wobbly path. A live arm model draws each rep.
- **Camera (any supported exercise):** Apple Vision body-pose detection (`VNDetectHumanBodyPoseRequest`) tracks your skeleton and counts squats, lunges, push-ups, presses, raises, triceps extensions and curls from joint angles.
- **Manual** for everything else: bench press, rows, deadlifts, crunches.

**Workouts**
- Built-in workouts: Arm day, Upper body, Full body starter, and Elbow mobility (rehab). You can also build your own: exercises, sets, reps, weight and rest.
- **Hands-free sets:**
  - the first rep starts the set, and a pause ends it
  - the rest timer starts automatically and calls out "10 seconds" before the end
  - the next set starts when you start lifting
  - rest is measured from the end of one set to the first rep of the next
- After each set you can fix the rep count and rate the effort (RPE 6–10).
- **Lifting speed per rep and speed loss**, like a bar-speed tracker. When speed drops 30% or more, the app tells you you're close to failure.
- **Progressive overload:** if you hit every set with good form and RPE 8 or less, next time's weight goes up a step. If you miss by 2 or more reps, it goes down a step.

**Progress**
- This week's workouts, reps and volume, plus your weekly streak.
- A 12-week activity grid and weekly volume chart.
- Per-exercise trends: estimated 1-rep max, top-set weight, total reps, form score, lifting speed and range of motion. Range of motion is useful for rehab.
- Personal records and full history, down to each rep.

**Camera tab**
- Live skeleton, joint angles and camera rep counting for any supported exercise.
- **SmartBell vs camera:** puts the sensor's forearm angle next to the camera's and measures the difference (mean, RMS and max), saved as CSV. Use it to report the sensor's accuracy against an independent measurement.

**Sensor tools**
- 15-second calibration that works however the box is strapped on.
- Raw CSV recording and replay, and a demo sensor so you can try everything without hardware.

## Install on your iPhone

You need a Mac with Xcode 15 or newer, and an iPhone on iOS 17+. A free Apple ID is enough.

1. Open `SmartBell.xcodeproj` in Xcode.
2. Click the **SmartBell** project › target **SmartBell** › **Signing & Capabilities**. Tick *Automatically manage signing* and choose your **Team** (your Apple ID; add it under Xcode › Settings › Accounts if it isn't listed).
   If Xcode says the bundle identifier is taken, change `ca.uwaterloo.ece198.smartbell` to something unique, e.g. add your name.
3. Plug in the iPhone, select it as the run destination at the top of Xcode, and press **Run** (⌘R).
4. First time only: on the phone, open **Settings › General › VPN & Device Management**, tap your Apple ID and **Trust** it. On iOS 16+ also turn on **Settings › Privacy & Security › Developer Mode** (the phone restarts).
5. Open SmartBell and allow Bluetooth (and the camera, when you first open the Camera tab).

With a free Apple ID the app stops opening after 7 days. Press Run in Xcode again to renew it.

## Using it

1. **Connect:** power the ESP32 and tap **Find SmartBell** on the **Train** tab. It reconnects automatically after the first time. To try the app without hardware, tap **Try demo**.
2. **Calibrate** (SmartBell only): strap the box on the back of the forearm just below the elbow. Let the arm hang still holding the dumbbell, then do 3 slow, full curls. Redo this whenever the strap moves.
3. **Start a workout:** on **Train**, tap ▶ on a workout or pick an exercise under **Quick start**.
4. **Tracking:** curls use the SmartBell when it's connected and calibrated. Exercises the camera supports use the camera. Prop the phone up so your whole body (or arm) is in view, side-on as the on-screen hint says. Everything else is manual. You can switch tracking at the top of the workout screen.
5. **Lift:** the first rep starts the set, and pausing for a few seconds ends it. Rest, rate the set if you like, and the next set starts when you start lifting.
6. **Review:** see the summary at the end, then check **Progress** and **History**.

Voice counting, form cues, workout guidance and vibration can each be turned off under **Device › Feedback**.

## Project layout

```
SmartBell/
  App/         SmartBellApp (tabs), AppModel (wires sensor, camera and workouts together)
  Motion/      Vec3, GravityTracker, RepDetector, MotionEngine, Calibrator   <- SmartBell algorithm
  Camera/      PoseCamera (AVFoundation + Vision), PoseGeometry (joint angles), AngleRepCounter, CameraLab
  Fitness/     ExerciseLibrary, WorkoutModels (sessions, sets, progression), WorkoutController, FitnessStats
  Sensor/      BLEManager (CoreBluetooth), DemoSensor (simulated arm), Recorder (CSV)
  Feedback/    Coach (haptics + speech)
  Storage/     WorkoutStore (fitness.json in Documents; imports old v2.0 sets)
  Views/       Train, workout player, Camera, Progress, History, Device, calibration, arm model
firmware/      ESP32 sketch (unchanged from the original repo)
tools/         Python reference implementation + simulator + evaluation + CSV replay
docs/          ALGORITHM.md, simulation plot
```

## Camera rep counting

Vision returns 2D joint positions. Each camera exercise tracks one joint angle:

| angle | measured as | used for |
|---|---|---|
| forearm angle | elbow→wrist vs straight down | curls |
| elbow bend | 180° − shoulder–elbow–wrist angle | presses, push-ups, triceps |
| knee bend | 180° − hip–knee–ankle angle | squats, lunges |
| arm raise | hip–shoulder–elbow angle | lateral and front raises |

It uses whichever side of the body is detected more confidently. `AngleRepCounter` applies the same hysteresis idea as the sensor's detector. Progress `p = (angle − rest) / (work − rest)`: a rep starts at p > 0.35, counts if the peak passed 0.8, and ends at p < 0.25. Because the angles are 2D, set the phone up the way each exercise's hint says (side-on or facing).

## Firmware contract

Unchanged. Advertises `SmartBell`, service `7b7e0001-9d8b-4f2a-a2b0-5c4e1a000001`, notify characteristic `7b7e0002-…`, newline-terminated CSV at ~100 Hz:

```
ax,ay,az,gx,gy,gz,dt_s      (m/s², °/s, seconds since previous read)
```

## Tuning on real data

The Python file `tools/smartbell_motion.py` mirrors `SmartBell/Motion/*.swift` line for line. Work on the algorithm there, then copy the change to Swift.

```bash
pip install numpy scipy matplotlib
cd tools
python3 evaluate.py --seeds 20               # simulated sessions: rep count, angle error, cue accuracy
python3 evaluate.py --plot angle.png         # one session, plotted
python3 replay_csv.py my-recording.csv --plot out.png   # a recording from the app (Device › Recordings › share)
```

To record: **Device › Record raw data**, do a set, stop, then share the file to your laptop. Write down what you actually did (e.g. "10 reps, #4 partial, #7 swung"), so the output can be checked against it.

If you add or move Swift files, add them in Xcode (File › Add Files). `tools/gen_xcodeproj.py` rebuilds the project from scratch and would reset Xcode's signing settings, so use it only as a last resort.

## Limits

- SmartBell accuracy numbers are from simulation only. Use the Camera tab's comparison, or labelled recordings, before quoting accuracy.
- The SmartBell tracks curls only. The angle-to-gravity method works because the forearm rotates about the elbow. A shoulder press moves the forearm mostly in translation and needs a different model (e.g. a sensor on the upper arm). Other exercises use the camera.
- Camera thresholds (rest and work angles per exercise) are reasonable starting values, not tuned on real people yet. Camera tracking needs decent light and the right side of your body in view.
- Progression and speed-loss advice follow common training rules of thumb. They aren't personalised coaching.
- The upper arm is assumed vertical when drawing the arm. A body swing or elbow drift shows up as the cues above, not in the drawing.
- Form cues are prototype feedback, not a clinical assessment.
