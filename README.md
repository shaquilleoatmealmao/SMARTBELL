# SmartBell v2

iPhone app for the SmartBell forearm sensor (ESP32 + BMX160). It counts bicep and hammer curls, draws each rep live, and coaches form by voice and vibration while the phone is in your pocket.

This is a rewrite of the app in `ez-codes-07/smart-bell`. The firmware is unchanged. The motion code is new: it no longer integrates acceleration, which is why the old rep counter drifted. See [docs/ALGORITHM.md](docs/ALGORITHM.md).

## What it does

- **Rep counting** from the forearm's angle to gravity. That angle can't drift, so counting is speed-independent and doesn't degrade over a set.
- **Live rep model:** a side view and front view of your arm, with the hand path of the current rep and a ghost of the previous one. The path is re-anchored at the start of every rep.
- **Form feedback after each rep:** swinging, elbow drifting forward, partial range at the top or bottom, lowering too fast, lifting too fast, wrist twisting, path drifting sideways. You get a score out of 100, a vibration, and the top cue spoken out loud.
- **Set summary:** reps vs. target, tempo, the issues to work on, and a gentle heavier/lighter hint. History keeps every set.
- **15-second calibration:** works however the box is strapped on, and learns your own range of motion.
- **Record and replay:** save the raw sensor stream as CSV, replay it in the app, or analyse it on a laptop with `tools/replay_csv.py`.
- **Demo sensor:** a physics-based simulated arm (with bias, noise and some deliberately bad reps), so you can try everything without the hardware.

## Install on your iPhone

You need a Mac with Xcode 15 or newer, and an iPhone on iOS 17+. A free Apple ID is enough.

1. Open `SmartBell.xcodeproj` in Xcode.
2. Click the **SmartBell** project › target **SmartBell** › **Signing & Capabilities**. Tick *Automatically manage signing* and choose your **Team** (your Apple ID; add it under Xcode › Settings › Accounts if it isn't listed).
   If Xcode says the bundle identifier is taken, change `ca.uwaterloo.ece198.smartbell` to something unique, e.g. add your name.
3. Plug in the iPhone, select it as the run destination at the top of Xcode, and press **Run** (⌘R).
4. First time only: on the phone, open **Settings › General › VPN & Device Management**, tap your Apple ID and **Trust** it. On iOS 16+ also turn on **Settings › Privacy & Security › Developer Mode** (the phone restarts).
5. Open SmartBell and allow Bluetooth.

With a free Apple ID the app stops opening after 7 days. Press Run in Xcode again to renew it.

## Using it

1. Power the ESP32 (USB from the phone, as now). On the **Workout** tab tap **Find SmartBell**. It reconnects automatically after the first time.
2. **Calibrate:** strap the box on the back of the forearm just below the elbow. Let the arm hang still holding the dumbbell, then do 3 slow, full curls. Redo this whenever the strap moves.
3. Pick the exercise, weight and target reps, then **Start set**. Put the phone in your pocket. The screen stays awake during a set so vibration and voice keep working.
4. Each rep is counted out loud on the way down. If something's off, you'll hear one short cue.
5. **End set** for the summary.

Voice, vibration and counting can each be turned off under **Device › Feedback**.

## Project layout

```
SmartBell/
  App/         SmartBellApp (tabs), AppModel (wires sensor → engine → UI/coach)
  Motion/      Vec3, GravityTracker, RepDetector, MotionEngine, Calibrator   ← the algorithm
  Sensor/      BLEManager (CoreBluetooth), DemoSensor (simulated arm), Recorder (CSV)
  Feedback/    Coach (haptics + speech)
  Storage/     WorkoutStore (history, JSON in Documents)
  Views/       Workout, live set, arm model, calibration, history, device/diagnostics
firmware/      ESP32 sketch (unchanged from the original repo)
tools/         Python reference implementation + simulator + evaluation + CSV replay
docs/          ALGORITHM.md, simulation plot
```

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

If you add or move Swift files, add them in Xcode or run `python3 tools/gen_xcodeproj.py`.

## Limits

- Accuracy numbers are from simulation only. They have not been validated against labelled recordings from the real device yet. Do that before quoting accuracy.
- Curls only. The angle-to-gravity method works because the forearm rotates about the elbow. A shoulder press moves the forearm mostly in translation and needs a different model (e.g. a sensor on the upper arm).
- The upper arm is assumed vertical when drawing the arm. A body swing or elbow drift shows up as the cues above, not in the drawing.
- Form cues are prototype feedback, not a clinical assessment.
