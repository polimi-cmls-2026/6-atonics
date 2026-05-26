import processing.serial.*;
import oscP5.*;
import netP5.*;

// NETWORK AND SERIAL VARIABLES
Serial myPort;
OscP5 oscP5;
NetAddress superColliderDest;
NetAddress juceDest;

// SENSOR DATA VARIABLES
int targetPot = 1;        // Encoder value (from 1 to 4)
int wetValue = 50;        // WET value (from 0 to 100)
int button = 0;           // Button value (Toggle)

// FLUID ANIMATION VARIABLES (GEOMETRY)
int currentDrawPot = 1;
float[] px = new float[5];
float[] py = new float[5];
float progressAngle = radians(160.5);

// FREEZE EFFECT AND WET INTERPOLATION VARIABLES
float freezeIntensity = 0;
float iceTime = 0;         
float displayWet = 0;     

// DROPDOWN MENU VARIABLES (SLOTS 2 AND 3)
String[] keys = {"C", "C#/Db", "D", "D#/Eb", "E", "F", "F#/Gb", "G", "G#/Ab", "A", "A#/Bb", "B"};
int selectedKeyIndex = 0;  
boolean dropdownOpen = false; 

// REACTIVE ELEMENTS OPACITY VARIABLES
float alphaCircle = 255;
float alphaLine   = 0;

// OSC STATE VARIABLES (ANTISPAM)
String lastSentRoot = "";
String lastSentMode = "";
int lastArduinoPot = -1;
int lastArduinoWet = -1;
int lastArduinoButton = -1;

String[] basicModes = {"Major", "Minor"};
int selectedModeIndex = 0;
boolean modeDropdownOpen = false;

void setup() {
  size(1000, 600);
  
  // ANIMATION SETUP
  for (int i = 0; i < 4; i++) {
    px[i] = 0;
    py[i] = 0;
  }
  
  // SERIAL SETUP
  printArray(Serial.list());
  String portName = Serial.list()[0];
  myPort = new Serial(this, portName, 115200);
  myPort.bufferUntil('\n'); 
  
  // OSC SETUP
  oscP5 = new OscP5(this, 12000);
  superColliderDest = new NetAddress("127.0.0.1", 57120); 
  juceDest = new NetAddress("127.0.0.1", 8000);
}

void draw() {
  // 0. MENU SAFETY CHECKS
  String[] currentModes = basicModes;
  if (selectedModeIndex >= currentModes.length) {
    selectedModeIndex = 0;
  }

  // 1. FREEZE TRANSITION AND SPEED LOGIC
  if (button == 1) {
    freezeIntensity = lerp(freezeIntensity, 1.0, 0.03);
  } else {
    freezeIntensity = lerp(freezeIntensity, 0.0, 0.08); 
  }
  
  float minSpeed = 0.008;
  float maxSpeed = 0.04; 
  float iceSpeed = map(wetValue, 0, 100, minSpeed, maxSpeed);
  iceTime += iceSpeed;
  displayWet = lerp(displayWet, wetValue, 0.15);
  
  // 2. REACTIVE BACKGROUND
  color normalBackground = color(30, 30, 30);       
  color iceBackground = color(25, 35, 50);
  background(lerpColor(normalBackground, iceBackground, freezeIntensity));
  
  // STATUS TEXTS
  //fill(255);
  //textAlign(LEFT, TOP);
  //textSize(12);
  //text("Bridge Serial -> OSC", 10, 10);
  //text("Vertices (Encoder): " + targetPot, 10, 30);
  //text("Potentiometer (Wet): " + wetValue, 10, 50);
  //text("Button: " + button, 10, 70);

  // GEOMETRY TARGET CALCULATION
  float R = 100;
  float[] targetX = new float[5];
  float[] targetY = new float[5];
  
  if (targetPot == 1) {
    targetX[0] = 0;   targetY[0] = -R;
    targetX[1] = 0;   targetY[1] = R;  
    targetX[2] = 0;   targetY[2] = R;  
    targetX[3] = 0;   targetY[3] = -R;
    targetX[4] = 0;   targetY[4] = R;
  }
  else if (targetPot == 2) {
    targetX[0] = 0;   targetY[0] = -R; 
    targetX[1] = R;   targetY[1] = R;  
    targetX[2] = -R;  targetY[2] = R;  
    targetX[3] = 0;   targetY[3] = -R;
    targetX[4] = 0;   targetY[4] = -R;
  }
  else if (targetPot == 3) {
    targetX[0] = R;   targetY[0] = -R; 
    targetX[1] = R;   targetY[1] = R;  
    targetX[2] = -R;  targetY[2] = R;  
    targetX[3] = -R;  targetY[3] = -R;
    targetX[4] = -R;  targetY[4] = -R;
  }
  else if (targetPot == 4) {
    targetX[0] = 0;              targetY[0] = -R; 
    targetX[1] = R*sin(PI*2/5);  targetY[1] = -R*cos(PI*2/5);  
    targetX[2] = R*sin(PI*4/5);  targetY[2] = -R*cos(PI*4/5);  
    targetX[3] = R*sin(PI*6/5);  targetY[3] = -R*cos(PI*6/5);
    targetX[4] = R*sin(PI*8/5);  targetY[4] = -R*cos(PI*8/5);
  }
  
  boolean isMoving = false;
  float speed = 0.15;
  for (int i = 0; i < 5; i++) {
    px[i] = lerp(px[i], targetX[i], speed);
    py[i] = lerp(py[i], targetY[i], speed);
    if (dist(px[i], py[i], targetX[i], targetY[i]) > 1.0) {
      isMoving = true;
    }
  }
  
  int pointsToDraw = max(currentDrawPot, targetPot+1);
  if (!isMoving) {
    currentDrawPot = targetPot+1;
  }
  
  // CONTENT 1: GEOMETRY (1/3)
  pushMatrix();
  translate(width / 3, height / 2);
  stroke(255, 150); 
  strokeWeight(3);
  noFill();
  
  if (pointsToDraw > 1) {
    beginShape();
    for (int i = 0; i < pointsToDraw; i++) {
      vertex(px[i], py[i]);
    }
    if (pointsToDraw > 2) {
      endShape(CLOSE);
    } else {
      endShape();
    }
  }
  
  for (int i = 0; i < pointsToDraw; i++) {
    noStroke();
    fill(0, 200, 255, 50); 
    ellipse(px[i], py[i], 45, 45); 
    fill(0, 200, 255); 
    ellipse(px[i], py[i], 20, 20); 
  }
  popMatrix();

  // CONTENT 2: WET GAUGE WITH REACTIVE ICON (2/3)
  pushMatrix();
  translate(2 * width / 3, height / 2 + 60); 
  int diameter = 240;
  
  noFill();
  stroke(0, 150, 255, 30); 
  strokeWeight(10); 
  strokeCap(ROUND);
  arc(0, 0, diameter, diameter, radians(160), radians(380));
  
  progressAngle = map(displayWet, 0, 100, radians(160.5), radians(380));
  stroke(0, 200, 255); 
  strokeWeight(14);
  arc(0, 0, diameter, diameter, radians(160), progressAngle);
  
  alphaLine = map(displayWet, 0, 100, 0, 255);
  float cx = 0;
  float cy = 15;
  float dCircle = 85;
  
  noFill();
  stroke(0, 200, 255, alphaCircle); 
  strokeWeight(5);
  ellipse(cx, cy, dCircle, dCircle);
  
  noFill();
  stroke(0, 200, 255, alphaLine); 
  strokeWeight(5);
  strokeJoin(ROUND); 
  strokeCap(ROUND);
    
  beginShape();
  vertex(-75, 45);  
  vertex(0, -60);   
  vertex(75, 45);   
  endShape();
  
  fill(0, 200, 255);
  textAlign(CENTER, CENTER); 
  textSize(32);
  text(wetValue, cx, cy - 3); 
  
  fill(200);
  textSize(14); 
  text("WET", 0, 85); 
  popMatrix();
  
  // 3. TITLE WITH OVAL SHADOW
  pushStyle();
  textAlign(CENTER, CENTER);
  textSize(64);
  // compute title position and width
  float tx = width / 2;
  float ty = height / 2 - 200;
  float tw = textWidth("6-Atonics");
  // draw soft oval shadow under the title (two layers for softness)
    noStroke();
    fill(0, 120, 170, 60);
    ellipse(tx, ty + 20, tw * 1.2, 48);
    fill(0, 90, 140, 40);
    ellipse(tx, ty + 26, tw * 1.35, 64);
  // draw main title on top
  fill(0, 200, 255);
  text("6-Atonics", tx, ty);
  popStyle();

  // BOTTOM SLOTS (positions adjusted across window width)
  pushMatrix();
  translate(int(width * 0.2 - (10 * 22) / 2.0), 460); 
  drawPianoSlot();
  popMatrix();

  pushMatrix();
  translate(int(width * 0.5 - 120 / 2.0), 500); 
  drawDropdownSlot();
  popMatrix();

  pushMatrix();
  translate(int(width * 0.8 - 120 / 2.0), 500); // MODE moved dynamically
  drawModeSlot(currentModes);
  popMatrix();

  drawFreezeEffect();
}

void drawFreezeEffect() {
  if (freezeIntensity < 0.01) return; 
  noStroke();
  fill(220, 245, 255, 200 * freezeIntensity); 
  float step = 4;
  float maxInward = 30 * freezeIntensity; 
  
  beginShape();
  for (float x = 0; x <= width; x += step) { float n = noise(x * 0.1, iceTime); vertex(x, n * maxInward); } 
  vertex(width, 0); vertex(0, 0); endShape(CLOSE);
  
  beginShape();
  for (float x = 0; x <= width; x += step) { float n = noise(x * 0.1, 500 + iceTime); vertex(x, height - (n * maxInward)); } 
  vertex(width, height); vertex(0, height); endShape(CLOSE);
  
  beginShape();
  for (float y = 0; y <= height; y += step) { float n = noise(y * 0.1, 1000 + iceTime); vertex(n * maxInward, y); } 
  vertex(0, height); vertex(0, 0); endShape(CLOSE);
  
  beginShape();
  for (float y = 0; y <= height; y += step) { float n = noise(y * 0.1, 1500 + iceTime); vertex(width - (n * maxInward), y); } 
  vertex(width, height); vertex(width, 0); endShape(CLOSE);
  
  noFill(); strokeWeight(15);
  for(int i = 0; i < 3; i++) { stroke(255, (15 - i*4) * freezeIntensity); rect(0, 0, width, height); }
}

void serialEvent(Serial myPort) {
  try {
    String val = myPort.readStringUntil('\n');
    if (val != null) {
      val = trim(val);
      if (val.startsWith("DATA,")) {
        String[] parts = split(val, ',');
        if (parts.length == 4) { 
          targetPot = int(parts[1]);
          wetValue = int(parts[2]);
          button = int(parts[3]);
          
          if (targetPot != lastArduinoPot) {
            OscMessage msgComp = new OscMessage("/complexity");
            msgComp.add(targetPot);
            oscP5.send(msgComp, superColliderDest);
            lastArduinoPot = targetPot;
          }
          if (wetValue != lastArduinoWet) {
            OscMessage msgMix = new OscMessage("/mix");
            msgMix.add(wetValue / 100.0f); 
            oscP5.send(msgMix, superColliderDest);
            lastArduinoWet = wetValue;
          }
          if (button != lastArduinoButton) {
            OscMessage msgFreeze = new OscMessage("/freeze");
            msgFreeze.add(button);
            oscP5.send(msgFreeze, superColliderDest);
            lastArduinoButton = button;
          }
          sendChordComplexity();
        }
      }
    }
  } catch (Exception e) { }
}

void drawPianoSlot() {
  int numWhiteKeys = 10;
  int keyWidth = 22; int keyHeight = 80;
  color keyOffColor = color(200);
  color keyOnColor = color(0, 200, 255);
  color blackKeyColor = color(30);
  
  String[] currentModes = basicModes;
  int safeModeIndex = (selectedModeIndex >= currentModes.length) ? 0 : selectedModeIndex;
  String mode = currentModes[safeModeIndex];
  
  int[] intervals = new int[targetPot+1];
  intervals[0] = 0; 
  intervals[1] = 7; 
  
  if (targetPot >= 2) {
    if (mode.equals("Minor")) { intervals[2] = 3; } 
    else { intervals[2] = 4; }
  }
  if (targetPot >= 3) {
    if (mode.equals("Minor")) { intervals[3] = 10; } 
    else { intervals[3] = 11; }
  }
  if (targetPot == 4) {
    intervals[4] = 14;
  }

  int[] whiteKeyMidiNote = {0, 2, 4, 5, 7, 9, 11, 12, 14, 16};
  
  stroke(50); strokeWeight(2);
  for (int i = 0; i < numWhiteKeys; i++) {
    int midiNoteTasto = whiteKeyMidiNote[i];
    boolean isNoteOn = false;
    for (int j = 0; j < intervals.length; j++) {
      if (intervals[j]  == midiNoteTasto) { isNoteOn = true; }
    }
    if (isNoteOn) fill(keyOnColor);
    else fill(keyOffColor);
    rect(i * keyWidth, 0, keyWidth, keyHeight, 0, 0, 3, 3);
  }

  int blackKeyWidth = 12;
  int blackKeyHeight = 45;
  int[] blackKeyMidiNote = {1, 3, -1, 6, 8, 10, -1, 13, 15};
  for (int i = 0; i < numWhiteKeys - 1; i++) {
    if (blackKeyMidiNote[i] != -1) {
      int midiNoteBlack = blackKeyMidiNote[i];
      float xBlack = (i * keyWidth) + keyWidth - (blackKeyWidth / 2.0);
      boolean isBlackOn = false;
      for (int j = 0; j < intervals.length; j++) {
        if (intervals[j] == midiNoteBlack) { isBlackOn = true; }
      }
      if (isBlackOn) fill(keyOnColor);
      else fill(blackKeyColor);
      stroke(50); strokeWeight(1);
      rect(xBlack, 0, blackKeyWidth, blackKeyHeight, 0, 0, 2, 2);
    }
  }

  fill(200); textAlign(CENTER, TOP); textSize(14);
  float keyboardCenter = (numWhiteKeys * keyWidth) / 2.0;
  String root = keys[selectedKeyIndex];
  String chordName = "";
  
  if (targetPot == 1) chordName = "POWER (" + root + "5)";
  else if (targetPot == 2) {
    String suffix = mode.equals("Minor") ? "min" : "maj";
    chordName = "TRIAD (" + root + suffix + ")";
  }
  else if (targetPot == 3) {
    String suffix = mode.equals("Minor") ? "min7" : "maj7";
    chordName = "QUATRIAD (" + root + suffix + ")";
  }
  else if (targetPot == 4) {
    String suffix = mode.equals("Minor") ? "min7 add9" : "maj7 add9";
    chordName = "EXTENDED (" + root + suffix + ")";
  }
  text(chordName, keyboardCenter, keyHeight + 15);
}

void drawDropdownSlot() {
  int w = 120; int h = 30;
  fill(200); textAlign(CENTER, BOTTOM); textSize(12); text("TONALITY", w/2, -8);
  if (dropdownOpen) {
    int itemH = 25; int totalH = keys.length * itemH;
    for (int i = 0; i < keys.length; i++) {
      int itemY = -totalH + (i * itemH);
      float mX = mouseX - 420; float mY = mouseY - 500;
      if (mX >= 0 && mX <= w && mY >= itemY && mY < itemY + itemH) fill(0, 130, 180);
      else if (i == selectedKeyIndex) fill(15, 60, 90); 
      else fill(40);
      stroke(60); strokeWeight(1); rect(0, itemY, w, itemH);
      fill(255); textAlign(CENTER, CENTER); textSize(12);
      text(keys[i], w/2, itemY + itemH/2);
    }
  }
  stroke(100); strokeWeight(1); if (dropdownOpen) fill(45, 65, 85); else fill(50);
  rect(0, 0, w, h, 4); fill(0, 200, 255); textAlign(CENTER, CENTER); textSize(14); text(keys[selectedKeyIndex], w/2 - 8, h/2);
  fill(180); noStroke(); pushMatrix();
  translate(w - 15, h/2); if (dropdownOpen) triangle(-4, 2, 4, 2, 0, -3); else triangle(-4, -2, 4, -2, 0, 3);
  popMatrix();
}

void drawModeSlot(String[] currentModes) {
  int w = 120; int h = 30;
  fill(200); textAlign(CENTER, BOTTOM); textSize(12);
  text("MODE", w/2, -8);
  if (modeDropdownOpen) {
    int itemH = 25; int totalH = currentModes.length * itemH;
    for (int i = 0; i < currentModes.length; i++) {
      int itemY = -totalH + (i * itemH);
      float mX = mouseX - 620; float mY = mouseY - 500; 
      if (mX >= 0 && mX <= w && mY >= itemY && mY < itemY + itemH) fill(0, 130, 180);
      else if (i == selectedModeIndex) fill(15, 60, 90); 
      else fill(40);
      stroke(60); strokeWeight(1); rect(0, itemY, w, itemH);
      fill(255); textAlign(CENTER, CENTER); textSize(12);
      text(currentModes[i], w/2, itemY + itemH/2);
    }
  }
  stroke(100); strokeWeight(1); if (modeDropdownOpen) fill(45, 65, 85); else fill(50);
  rect(0, 0, w, h, 4); fill(0, 200, 255); textAlign(CENTER, CENTER); textSize(14); text(currentModes[selectedModeIndex], w/2 - 8, h/2);
  fill(180); noStroke(); pushMatrix();
  translate(w - 15, h/2); if (modeDropdownOpen) triangle(-4, 2, 4, 2, 0, -3); else triangle(-4, -2, 4, -2, 0, 3); popMatrix();
}

void mousePressed() {
  
  int s2X = 420, s2Y = 500, w = 120, h = 30;
  int s3X = 620, s3Y = 500; 

  // DROPDOWN MENU CLICK
  if (mouseX >= s2X && mouseX <= s2X + w && mouseY >= s2Y && mouseY <= s2Y + h) { 
    dropdownOpen = !dropdownOpen;
    if (dropdownOpen) modeDropdownOpen = false; 
    return; 
  }
  if (mouseX >= s3X && mouseX <= s3X + w && mouseY >= s3Y && mouseY <= s3Y + h) { 
    modeDropdownOpen = !modeDropdownOpen;
    if (modeDropdownOpen) dropdownOpen = false; 
    return; 
  }
  
  if (dropdownOpen) {
    int itemH = 25;
    int totalH = keys.length * itemH;
    for (int i = 0; i < keys.length; i++) {
      int itemY = s2Y - totalH + (i * itemH);
      if (mouseX >= s2X && mouseX <= s2X + w && mouseY >= itemY && mouseY < itemY + itemH) { 
        selectedKeyIndex = i;
        dropdownOpen = false; 
        sendChordComplexity(); 
        return; 
      }
    }
    dropdownOpen = false;
  }
  
  if (modeDropdownOpen) {
    String[] currentModes = basicModes;
    int itemH = 25;
    int totalH = currentModes.length * itemH;
    for (int i = 0; i < currentModes.length; i++) {
      int itemY = s3Y - totalH + (i * itemH);
      if (mouseX >= s3X && mouseX <= s3X + w && mouseY >= itemY && mouseY < itemY + itemH) { 
        selectedModeIndex = i;
        modeDropdownOpen = false; 
        sendChordComplexity(); 
        return; 
      }
    }
    modeDropdownOpen = false;
  }
}

void sendChordComplexity() {
  String[] currentModes = basicModes;
  int safeModeIndex = (selectedModeIndex >= currentModes.length) ? 0 : selectedModeIndex;

  String currentRoot = keys[selectedKeyIndex];
  String currentMode = currentModes[safeModeIndex];

  if (!currentRoot.equals(lastSentRoot) || !currentMode.equals(lastSentMode)) {
    
    int midiTonic = 60;
    for(int i = 0; i < keys.length; i++) {
        if(keys[i].equals(currentRoot)) {
            midiTonic = 60 + i;
            break;
        }
    }
    
    int modeInt = currentMode.equals("Minor") ? 1 : 0;
    
    OscMessage msgTonic = new OscMessage("/tonic");
    msgTonic.add(midiTonic); 
    oscP5.send(msgTonic, superColliderDest);

    OscMessage msgMode = new OscMessage("/mode");
    msgMode.add(modeInt);
    oscP5.send(msgMode, superColliderDest);

    lastSentRoot = currentRoot;
    lastSentMode = currentMode;
  }
}
