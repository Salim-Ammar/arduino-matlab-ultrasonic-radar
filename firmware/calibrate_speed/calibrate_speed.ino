#include <Servo.h>

Servo servo;
const int SERVO_PIN = 9;
int pulse = 1750;
int state = 0;

unsigned long lastReport = 0;

void setup() {
  Serial.begin(115200);
  servo.attach(SERVO_PIN);
  servo.writeMicroseconds(pulse);

  Serial.println(F("=== Servo Speed Calibration ==="));
  Serial.println(F("Servo spinning. Adjust speed:"));
  Serial.println(F("  + / -       inc/dec 1 us"));
  Serial.println(F("  ++ / --     inc/dec 10 us"));
  Serial.println(F("  1530        set pulse directly (any number)"));
  Serial.println(F("  ok          lock speed"));
  Serial.print(F("Pulse: "));
  Serial.print(pulse);
  Serial.println(F(" us"));
}

void loop() {
  servo.writeMicroseconds(pulse);

  if (state == 0) {
    if (Serial.available()) {
      String cmd = Serial.readStringUntil('\n');
      cmd.trim();

      if (cmd == "+")          { pulse++; }
      else if (cmd == "-")     { pulse--; }
      else if (cmd == "++")    { pulse += 10; }
      else if (cmd == "--")    { pulse -= 10; }
      else if (cmd == "ok") {
        state = 1;
        Serial.println(F("\nSpeed locked!"));
        Serial.println(F("--- Phase 2 ---"));
        Serial.println(F("Servo keeps rotating. Measure 1 full rotation,"));
        Serial.println(F("enter seconds (e.g. 10.124):"));
        return;
      }
      else {
        long n = cmd.toInt();
        if (n > 0 && n != pulse) {
          pulse = (int)n;
        }
      }

      Serial.print(F("Pulse: "));
      Serial.print(pulse);
      Serial.println(F(" us"));
    }
  }

  if (state == 1) {
    if (millis() - lastReport > 5000) {
      lastReport = millis();
      Serial.println(F("[Still waiting for rotation time...]"));
    }

    if (Serial.available()) {
      String input = Serial.readStringUntil('\n');
      input.trim();
      float sec = input.toFloat();

      if (sec > 0.0f) {
        float totalMs = sec * 1000.0f;
        float degPerMs = 360.0f / totalMs;
        float degPerS = 360.0f / sec;

        servo.writeMicroseconds(1500);

        Serial.println(F("\n=== Calibration Complete ==="));
        Serial.println(F("Copy into scanner.ino:"));
        Serial.println(F(""));
        Serial.print(F("#define SERVO_SCAN    "));
        Serial.println(pulse);
        Serial.println(F("// SERVO_RETURN needs separate calibration if CCW also changed"));
        Serial.print(F("#define SCAN_DURATION_MS     "));
        Serial.println((unsigned long)(sec * 1000.0f));
        Serial.println(F(""));
        Serial.println(F("These are derived:"));
        Serial.print(F("// SCAN_SPEED_DEG_PER_S = 360.0f / "));
        Serial.print(sec, 3);
        Serial.println(F("f;"));
        Serial.print(F("#define SCAN_SPEED_DEG_PER_S   "));
        Serial.println(degPerS, 4);

        state = 2;
      } else {
        Serial.println(F("Invalid. Enter positive number (e.g. 10.124):"));
      }
    }
  }

  delay(20);
}
