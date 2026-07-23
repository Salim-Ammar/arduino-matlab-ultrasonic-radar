# Servo Calibration Guide

Every continuous-rotation servo has slightly different pulse-width-to-speed characteristics. Calibrating yours takes 2 minutes and ensures accurate 360° coverage.

## What You Need

- Arduino Nano
- SG90 (modified for continuous rotation)
- USB cable

## Step 1: Upload `calibrate_speed.ino`

Open `firmware/calibrate_speed/calibrate_speed.ino` in Arduino IDE and upload to your Nano.

Open Serial Monitor at **115200 baud**. The servo will start spinning and you'll see:

```
=== Servo Speed Calibration ===
Servo spinning. Adjust speed:
  + / -       inc/dec 1 us
  ++ / --     inc/dec 10 us
  1530        set pulse directly (any number)
  ok          lock speed
Pulse: 1750 us
```

## Step 2: Find the Right Pulse Width

Send commands in the Serial Monitor:

- `+` : increase pulse by 1µs (slower CW rotation)
- `-` : decrease pulse by 1µs (faster CW rotation)
- `++` / `--` : adjust by 10µs
- `1530` : set exact value

**Target:** The slowest reliable rotation that doesn't stall. Usually 1700–1800µs for CW, 1200–1300µs for CCW.

## Step 3: Measure Rotation Time

Once the speed looks right, type `ok`.

The firmware locks the speed and waits:

```
Speed locked!
--- Phase 2 ---
Servo keeps rotating. Measure 1 full rotation,
enter seconds (e.g. 10.124):
```

Time **one full rotation** with a stopwatch and enter the value in seconds (e.g., `10.124`).

## Step 4: Copy Results

The tool outputs ready-to-use `#define` values:

```
=== Calibration Complete ===
Copy into scanner.ino:

#define SERVO_SCAN    1720
// SERVO_RETURN needs separate calibration if CCW also changed
#define SCAN_DURATION_MS     10124
```

Update `scanner.ino` with these values.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Servo doesn't spin | Check wiring: brown=GND, red=5V, orange=signal |
| Rotation is jerky | 5V power may be insufficient. Add 10µF cap across servo power |
| One direction is faster than the other | SG90 is asymmetric. Calibrate SCAN and RETURN separately |
| I can't get exactly 360° | Slight over/under-rotation is normal. The firmware handles return |
