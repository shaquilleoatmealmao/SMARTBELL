# How SmartBell tracks a curl without drift

## Why the old app drifted

The old app integrated the gyro to get angles, then rotated the accelerometer, subtracted gravity and double-integrated to get position. Every error source compounds:

- A gyro bias of 2 °/s becomes a 120° angle error after one minute. In the simulation below, raw gyro integration ends a 90-second session 177° off.
- A 1° tilt error leaves 0.17 m/s² of gravity in the "linear" acceleration. Double integration turns that into 0.9 m of position error after 3 seconds.
- Fixed noise thresholds can't separate noise from motion, because during a rep the real motion is far above any threshold you can set.

No filter fixes double integration of a cheap IMU. The fix is to stop needing it.

## What we measure instead

The sensor is strapped to the forearm. During a curl the forearm is a rigid bar rotating about the elbow, so the rep is captured by one number:

> **β = angle between the forearm and straight down.** 0° = arm hanging, 90° = forearm horizontal, about 140° = top of a curl.

β is an angle *to gravity*, and the direction of gravity can be measured. So β has an absolute reference and its error stays bounded no matter how long the session runs.

## 1. Gravity tracker (`GravityTracker.swift`)

State: `u`, the "up" direction expressed in the sensor frame, plus the gyro bias `b`.

Every sample (a in m/s², ω in °/s, dt in s):

1. **Remove lever-arm acceleration.** The sensor sits r ≈ 6 cm from the elbow, so it also feels centripetal and tangential acceleration: `a_rot = ω×(ω×r·f) + α×r·f`. Subtract it.
2. **Low-pass** the result at 8 Hz → `ā`.
3. **Predict with the gyro:** a world-fixed vector seen from a rotating body turns by −ω·dt, so `u ← rotate(u, −(ω−b)·dt)`. This is smooth and responsive, but it drifts.
4. **Correct with the accelerometer:** `u ← normalize(u + k·trust·dt·(ā/|ā| − u))`, where
   `trust = exp(−((|ā| − g)/1 m/s²)²)`. If the measured acceleration looks like gravity (|ā| ≈ g), it pulls `u` toward the truth. During a hard swing (|ā| far from g) trust drops to ~0 and the gyro carries `u` alone for that moment.
   `k` is 1.5 /s while moving (time constant ~0.7 s) and 10 /s when still.
5. **Re-learn the gyro bias whenever you're still.** If the bias-corrected gyro is under 6 °/s and the accelerometer isn't shaking for 0.25 s, the gyro should read zero. Whatever it reads is bias, so `b` moves toward it. This happens at the bottom of every rep and between sets, so bias drift (temperature, time) is tracked continuously.

This is a complementary filter (the same idea as Mahony/Madgwick, restricted to the gravity direction). Tilt is fully observable from gravity, so the error stays bounded.

β is then `acos(−f·u)`, where `f` is the forearm direction in the sensor frame from calibration.

## 2. Calibration (`Calibrator.swift`, ~15 s)

Nothing about the mounting is hard-coded, so it doesn't matter which way the box is strapped on (the housing rotation that changed "which axis sees the curl" no longer matters).

1. **Arm hangs still for 2 s.** Gravity then points along the forearm, so `f = −mean(a)/|mean(a)|`. The mean gyro reading is the starting bias, and |mean(a)| is this accelerometer's own value of g (scale error).
2. **Three slow curls.** The elbow hinge axis `h` is the dominant rotation axis: the principal eigenvector of the gyro covariance, found by power iteration and made orthogonal to `f`. The median bottom and top of these curls become *your* range. Their average shape (40-point, time-normalised) becomes the reference "good rep". Typical twist and sway are recorded too, so the form checks are relative to your own baseline.

## 3. Rep detection (`RepDetector.swift`)

A hysteresis state machine on β, with thresholds set as fractions of your calibrated range (ROM):

| threshold | value | meaning |
|---|---|---|
| start | bottom + 30% ROM | a rep has begun |
| count | bottom + 70% ROM | the peak must pass this to count as a full rep |
| return | bottom + 22% ROM | the rep is over |

- The rep counts **on the way down**, the moment β falls back through *return* with a peak above *count*. The phone buzzes and says the number.
- If β drops by ≥45% of ROM and then rises by 12° without reaching *return* (you didn't lower all the way), the rep is closed at that valley and the next one starts there. Short-bottom reps don't merge into one.
- A peak between *start* and *count* is a **partial**: not counted, and the cue is "Curl all the way up".

Because β is an absolute, low-noise angle, the same thresholds work at any speed. The old counter was unreliable at higher speeds; here, speed only changes the timing numbers.

## 4. The rep's 3D path, re-anchored every rep (`MotionEngine.swift`)

Gravity gives tilt but not heading (which way you're facing). For the "what did the rep look like" picture the engine keeps a horizontal reference vector that only the gyro turns. It may wander slowly over minutes, and that's fine, because **at the start of every rep the frame is re-anchored**: the direction the hand is moving becomes "forward" for that rep. A rep lasts 2–3 s, and with the bias re-learned at every pause, heading error inside one rep is well under 1°. Nothing carries over to the next rep.

This is the "reset the position after each rep" idea. It's applied to the one quantity that needs it (heading). The angle never needed resetting because it never drifts.

The hand direction in the rep frame (forward, side, up) is drawn as the side view and front view in the app.

## 5. Form checks (per rep, in `RepDetector.analyse`)

| cue | measurement | threshold |
|---|---|---|
| Don't swing | peak elbow/body acceleration `|ā − g·u|` (after removing lever-arm terms). With good form the elbow is a fixed pivot, so this stays near 0. | > 4 m/s² |
| Elbow pinned | peak β above your calibrated top (the elbow moved forward, so the forearm went past where it can with the upper arm vertical) | > top + 18° |
| Curl higher | peak β below your calibrated top | < top − 20° |
| Lower fully | bottom β above your calibrated bottom | > bottom + 20° |
| Lower slower | time from top band to bottom band (5° bands) | < 0.7 s |
| Lift with control | time from bottom band to top band | < 0.35 s |
| Wrist twisting | range of gyro rotation about the forearm during the rep | > max(30°, 2×yours + 10°) |
| Straight path | the hand path is fitted to a vertical plane, and this is the peak-to-peak deviation from it | > max(15°, 2×yours + 8°) |

Score = 100 minus a penalty per issue. Only the highest-priority cue is spoken, and the same cue isn't repeated within 6 s.

The *lift*/*lower* times are measured between 5° bands at the bottom and top. They come out about 70% of the full movement time, so "about 2 seconds" of lowering reads ~1.4 s in the app.

## Validation (simulation)

`tools/simulate.py` is a physics model of a forearm-mounted IMU: arbitrary mounting rotation, gyro bias 2–3 °/s with random walk, gyro/accel noise, 3% accelerometer scale error, timing jitter, dropped BLE packets, a 6 cm lever arm, and scripted good and bad reps. `tools/evaluate.py` runs calibration and then the engine on it.

| condition | sessions with exact rep count | forearm-angle RMSE |
|---|---|---|
| baseline (20 random seeds) | 20/20 | 1.3° |
| bias 6 °/s, 2× noise | 10/10 | 1.8° |
| 30% of packets lost | 10/10 | 1.6° |
| accel scale 0.95 | 10/10 | 1.3° |
| lever 2 cm / 10 cm | 10/10 | 1.3° |

In the baseline runs every kind of bad rep got the right cue in every seed, and good reps got no false cues (also true in all the stress conditions). See `simulated-angle.png`: the blue estimate tracks the truth within a few degrees for the whole session, while plain gyro integration (red) drifts away.

**This is simulation, not measured data.** Real arms add skin/strap movement, the ESP32's real noise and timing, and people who don't move like a script. Before claiming accuracy, record real sets (Device › Record), label them by hand, and run `tools/replay_csv.py` on them. All thresholds are in one place (`MotionModels.swift` / `smartbell_motion.py`) for tuning.

## 6. Teaching SmartBell any exercise (`ExerciseProfile.swift`)

Curls are built in. For every other exercise, you teach SmartBell once: hold the start position still for 1.5 s, do 3 reps, then hold still. The app records that and learns a **profile** of the movement. From then on it turns the live sensor data into one number, **progress = % of your learned range** (0 = start position, 100 = end of the rep). That number feeds the same rep detector as curls (start 30%, count 70%, return 22%).

A forearm sensor can see a rep in two ways, and teaching tries both:

**Orientation (preferred).** Used when the forearm tilts during the rep: lateral and front raises, push-ups, triceps extensions, crunches. While teaching, the app records the gravity direction in the start position (`u_start`) and the direction at the far end of the rep (`u_end`, averaged over the 3 rep peaks). Live, the current gravity direction is projected onto the arc between them:

```
axis = normalize(u_start × u_end),  range = angle(u_start, u_end)
progress = 100 · atan2(axis · (u_start × u_p), u_start · u_p) / range     (u_p = u with its axis part removed)
```

This uses the same gravity tracker as curls, so it can't drift.

**Vertical movement.** Used when the forearm mostly moves up and down without tilting: squats, presses, rows, deadlifts. The vertical acceleration comes from `|a| − g_ref`. Because `|g + a_lin| = g + (vertical part of a_lin)` to first order however the sensor is tilted, this needs no orientation estimate, so gyro drift can't leak in. It is integrated twice for height, with three safeguards against drift:
- **Still:** velocity is zeroed whenever the arm is still (a zero-velocity update), and `g_ref` is re-learned then.
- **Bleed:** velocity bleeds slowly toward zero (15 s time constant).
- **Re-anchor:** height is reset to zero at the start of every rep. That's the moment velocity clearly heads outward again (past 25% of the learned peak speed), which means you've just left the start position. This is the "reset the position after each rep" idea: errors only live for one rep.

The tracker's stillness check also compares the acceleration filtered at 8 Hz with a 1 Hz copy. Without that, a smooth squat (no rotation) would look "still" and corrupt the bias and g estimates. Counting at a constant speed can't use "zero acceleration means stopped" either, because mid-rep the acceleration is also zero.

**Choosing.** Each candidate profile is checked by replaying the teaching recording through the real engine. The one that finds the most reps with the most consistent peaks wins, and orientation gets a bonus because it can't drift. The learned profile also stores a 40-point template of your rep and your normal wrist twist.

**Form for taught exercises** is judged on what the progress signal supports:
- partial rep, not far enough, or not back to the start
- going out or coming back too fast
- wrist twist

The curl-specific checks (swing, elbow, sideways path) apply to curls only.

### Validation (simulation)

`tools/simulate_exercises.py` simulates five exercises with the forearm sensor: squat, shoulder press, lateral raise, bent-over row, push-up. It includes a random mounting rotation, gyro bias, noise, a 3% accelerometer scale error and dropped packets. Each run teaches 3 reps, rests 8 s, then does a set of 8: one partial, one fast, the rest normal. Over 20 random seeds:

| exercise | channel learned | sets with all 7 full reps counted exactly |
|---|---|---|
| lateral raise | orientation | 20/20 |
| push-up | orientation | 20/20 |
| shoulder press | vertical | 20/20 |
| squat | vertical | 15/20 |
| bent-over row | vertical | 14/20 |

Orientation exercises are as reliable as curls. Vertical ones usually count correctly. Their errors were mostly the deliberate half-depth partial being counted as a full rep (or an extra partial appearing) right after the fast rep. In other words, depth and range judgements are approximate on that channel, which the app says when you teach one. Again, this is simulation: check real sets with recordings before quoting numbers.
