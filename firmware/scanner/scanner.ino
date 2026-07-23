#include <Arduino.h>
#include <Servo.h>

Servo scannerServo;

#define TRIG_PIN      10
#define ECHO_PIN      11
#define SERVO_PIN     9
#define LM35_CHAN     0       // LM35 on A0 → ADC channel 0

const unsigned int SERVO_STOP    = 1500;
const unsigned int SERVO_SCAN    = 1250;    // CCW (actual CW: scan forward)
const unsigned int SERVO_RETURN  = 1750;    // CW  (actual CCW: return home)
const unsigned long MEASURE_INTERVAL_MS = 8;
const unsigned long SCAN_DURATION_MS     = 2510;
const unsigned long RETURN_DURATION_MS   = 2510;
const float SCAN_SPEED_DEG_PER_S   = 360.0f * 1000.0f / SCAN_DURATION_MS;
const float RETURN_SPEED_DEG_PER_S = 360.0f * 1000.0f / RETURN_DURATION_MS;
const int TEMP_SAMPLES  = 8;
const int DIST_SAMPLES  = 1;
const int COMMAND_BUFFER_SIZE = 32;

// Temperature calibration offset (°C).
// If the LM35 reads systematically high (common with electrical noise),
// set this positive to subtract the error.  Example: reading shows 69°C
// at actual 25°C room temp → set to 44.0f.
const float TEMP_CAL_OFFSET = 0.0f;

enum ScanState { IDLE, SCANNING, RETURNING };
ScanState scanState = IDLE;
unsigned long stateStartMillis = 0;
unsigned long lastMeasureMillis = 0;
float vccMV = 5000.0f;        // measured VCC in mV, updated periodically
float lastDistanceMm = 0;
float lastTempC = 25.0f;

// Non-blocking measurement state machine
enum MeasState { MEAS_IDLE, MEAS_RUNNING };
MeasState measState = MEAS_IDLE;
unsigned long measStartUs = 0;
unsigned long measEchoRiseUs = 0;
int measTempIdx = 0;
long measTempSum = 0;
float measAngle = 0;
bool measEchoHigh = false;
bool measSkipTemp = false;
int measSkipTempCounter = 0;

char commandBuffer[COMMAND_BUFFER_SIZE];
int commandIndex = 0;

// Forward declarations
void processSerialCommands();
void trimCommand(char *cmd);
void executeCommand(const char *cmd);
void startScan();
void startReturn();
void stopMotion();
void startMeasurement(float angle);
void runMeasurementStep();
void finishMeasurement();
void measureVCC();
float median(float *values, int count);
void sendMeasurement(float angle, float distanceMm, float temperatureC);

void setup() {
  Serial.begin(250000);
  pinMode(TRIG_PIN, OUTPUT);
  digitalWrite(TRIG_PIN, LOW);
  pinMode(ECHO_PIN, INPUT);

  scannerServo.attach(SERVO_PIN);
  scannerServo.writeMicroseconds(SERVO_STOP);

  ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
  DIDR0 = (1 << ADC0D);

  for (int i = 0; i < 5; i++) {
    measureVCC();
    delay(5);
  }

  delay(200);
  Serial.println("READY");
}

void loop() {
  processSerialCommands();

  unsigned long now = millis();

  if (scanState == SCANNING) {
    if (now - stateStartMillis >= SCAN_DURATION_MS) {
      measState = MEAS_IDLE;
      sendMeasurement(360.0f, lastDistanceMm, lastTempC);
      startReturn();
    }
    if (now - lastMeasureMillis >= MEASURE_INTERVAL_MS && measState == MEAS_IDLE) {
      lastMeasureMillis = now;
      float angle = constrain((now - stateStartMillis) * 0.001f * SCAN_SPEED_DEG_PER_S, 0.0f, 360.0f);
      startMeasurement(angle);
    }
  } else if (scanState == RETURNING) {
    if (now - stateStartMillis >= RETURN_DURATION_MS) {
      stopMotion();
    }
  }

  if (measState == MEAS_RUNNING) {
    runMeasurementStep();
  }
}

void processSerialCommands() {
  while (Serial.available() > 0) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (commandIndex > 0) {
        commandBuffer[commandIndex] = '\0';
        trimCommand(commandBuffer);
        executeCommand(commandBuffer);
        commandIndex = 0;
      }
    } else if (commandIndex < COMMAND_BUFFER_SIZE - 1) {
      commandBuffer[commandIndex++] = c;
    }
  }
}

void trimCommand(char *cmd) {
  char *start = cmd;
  while (*start && isspace((unsigned char)*start)) {
    start++;
  }
  if (start != cmd) {
    memmove(cmd, start, strlen(start) + 1);
  }

  int len = strlen(cmd);
  while (len > 0 && isspace((unsigned char)cmd[len - 1])) {
    cmd[--len] = '\0';
  }
}

void executeCommand(const char *cmd) {
  if (strcasecmp(cmd, "START") == 0) {
    if (scanState == IDLE) {
      startScan();
      Serial.println("STARTED");
    }
  } else if (strcasecmp(cmd, "STOP") == 0) {
    stopMotion();
    Serial.println("STOPPED");
  }
}

void startScan() {
  scanState = SCANNING;
  stateStartMillis = millis();
  lastMeasureMillis = stateStartMillis;
  scannerServo.writeMicroseconds(SERVO_SCAN);
}

void startReturn() {
  scanState = RETURNING;
  stateStartMillis = millis();
  lastMeasureMillis = stateStartMillis;
  Serial.println("SCAN_COMPLETE");
  scannerServo.writeMicroseconds(SERVO_RETURN);
}

void stopMotion() {
  scanState = IDLE;
  scannerServo.writeMicroseconds(SERVO_STOP);
  Serial.println("DONE");
}

void startMeasurement(float angle) {
  measState = MEAS_RUNNING;
  measAngle = angle;
  measTempIdx = 0;
  measTempSum = 0;
  measEchoHigh = false;

  measSkipTempCounter++;
  if (measSkipTempCounter >= 10) {
    measSkipTempCounter = 0;
    measSkipTemp = false;
    ADMUX = (1 << REFS0) | (LM35_CHAN & 0x0F);
    ADCSRA |= (1 << ADSC);
  } else {
    measSkipTemp = true;
  }

  digitalWrite(TRIG_PIN, LOW);
  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH);
  delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);

  measStartUs = micros();
}

void runMeasurementStep() {
  unsigned long now = micros();

  if (!measSkipTemp && measTempIdx < TEMP_SAMPLES && !(ADCSRA & (1 << ADSC))) {
    uint8_t low = ADCL;
    uint8_t high = ADCH;
    measTempSum += low | ((uint16_t)high << 8);
    measTempIdx++;
    if (measTempIdx < TEMP_SAMPLES) {
      ADCSRA |= (1 << ADSC);
    }
  }

  int echo = digitalRead(ECHO_PIN);

  if (!measEchoHigh) {
    if (echo == HIGH) {
      measEchoHigh = true;
      measEchoRiseUs = now;
    } else if (now - measStartUs > 9000UL) {
      lastDistanceMm = 0;
      finishMeasurement();
      return;
    }
  } else {
    if (echo == LOW) {
      unsigned long duration = now - measEchoRiseUs;
      if (duration >= 100 && duration < 9000) {
        float speedOfSound = 331.3f + 0.606f * lastTempC;
        float usPerMm = 2000.0f / speedOfSound;
        lastDistanceMm = duration / usPerMm;
        if (lastDistanceMm < 20.0f || lastDistanceMm > 4000.0f) {
          lastDistanceMm = 0;
        }
      } else {
        lastDistanceMm = 0;
      }
      finishMeasurement();
      return;
    } else if (now - measStartUs > 18000UL) {
      lastDistanceMm = 0;
      finishMeasurement();
      return;
    }
  }
}

void finishMeasurement() {
  if (!measSkipTemp && measTempIdx > 0) {
    float averageAdc = measTempSum / (float)measTempIdx;
    float tempC = averageAdc * (vccMV / 1023.0f) / 10.0f;
    tempC -= TEMP_CAL_OFFSET;
    if (isfinite(tempC) && tempC >= -15.0f && tempC <= 85.0f) {
      lastTempC = lastTempC * 0.85f + tempC * 0.15f;
    }
  }

  sendMeasurement(measAngle, lastDistanceMm, lastTempC);
  measState = MEAS_IDLE;
}

void measureVCC() {
  ADMUX = (1 << REFS0) | 14;
  delayMicroseconds(100);
  ADCSRA |= (1 << ADSC);
  while (ADCSRA & (1 << ADSC));
  uint8_t low = ADCL;
  uint8_t high = ADCH;
  uint16_t raw = low | ((uint16_t)high << 8);
  if (raw > 50) {
    vccMV = 1100.0f * 1023.0f / raw;
  }
}



float median(float *values, int count) {
  for (int i = 1; i < count; i++) {
    float key = values[i];
    int j = i - 1;
    while (j >= 0 && values[j] > key) {
      values[j + 1] = values[j];
      j--;
    }
    values[j + 1] = key;
  }

  if (count % 2 == 1) {
    return values[count / 2];
  }
  return (values[count / 2 - 1] + values[count / 2]) * 0.5f;
}

void sendMeasurement(float angle, float distanceMm, float temperatureC) {
  Serial.print(angle, 1);
  Serial.print(',');
  Serial.print(distanceMm, 2);
  Serial.print(',');
  Serial.println(temperatureC, 2);
}
