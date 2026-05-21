import processing.serial.*;
import oscP5.*;
import netP5.*;

// --- VARIABILI DI RETE E SERIALE ---
Serial myPort;
OscP5 oscP5;
NetAddress superColliderDest;
NetAddress juceDest;

// --- VARIABILI DATI SENSORI ---
int targetPot = 2;        // Valore dell'encoder (da 1 a 4)
int wetValue = 0;         // Valore WET (da 0 a 100)
int button = 0;           // Valore pulsante (Toggle)

// --- VARIABILI PER L'ANIMAZIONE FLUIDA (GEOMETRIA) ---
int currentDrawPot = 1;
float[] px = new float[5];
float[] py = new float[5];

float angoloProgresso = radians(160.5);

// --- VARIABILI PER L'EFFETTO FREEZE E INTERPOLAZIONE WET ---
float freezeIntensity = 0;
float iceTime = 0;         
float displayWet = 0;     // Variabile fluida per la transizione del gauge e delle opacità

// --- VARIABILI PER I MENU A TENDINA (SLOT 2 e 3) ---
String[] keys = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
int selectedKeyIndex = 0;  
boolean dropdownOpen = false; 

// --- VARIABILI DI STATO OSC (ANTISPAM ACCORDI) ---
String lastSentRoot = "";
String lastSentMode = "";

// --- VARIABILI DI STATO OSC (ANTISPAM SENSORI) ---
int lastArduinoPot = -1;
int lastArduinoWet = -1;
int lastArduinoButton = -1;

String[] basicModes = {"Maggiore", "Minore"};
// Removed detailed seventh modes: UI shows only basicModes now
int selectedModeIndex = 0;
boolean modeDropdownOpen = false;

void setup() {
  size(1000, 600);
  
  // SETUP ANIMAZIONE
  for (int i = 0; i < 4; i++) {
    px[i] = 0;
    py[i] = 0;
  }
  
  // SETUP SERIALE
  printArray(Serial.list());
  String portName = Serial.list()[7];
  myPort = new Serial(this, portName, 115200);
  myPort.bufferUntil('\n'); 
  
  // SETUP OSC
  oscP5 = new OscP5(this, 12000);
  superColliderDest = new NetAddress("127.0.0.1", 57120); 
  juceDest = new NetAddress("127.0.0.1", 8000);
}

void draw() {
  // --- 0. CONTROLLI DI SICUREZZA MENU ---
  // Mostra sempre solo i due modi base nel menu a tendina
  String[] currentModes = basicModes;
  if (selectedModeIndex >= currentModes.length) {
    selectedModeIndex = 0;
  }

  // --- 1. LOGICA DI TRANSIZIONE FREEZE & VELOCITÀ ---
  if (button == 1) {
    freezeIntensity = lerp(freezeIntensity, 1.0, 0.03);
  } else {
    freezeIntensity = lerp(freezeIntensity, 0.0, 0.08); 
  }
  
  float velocitaMinima = 0.008;
  float velocitaMassima = 0.04; 
  float velocitaGhiaccio = map(wetValue, 0, 100, velocitaMinima, velocitaMassima);
  iceTime += velocitaGhiaccio; 
  
  // Movimento graduale per l'interfaccia grafica (Lerp)
  displayWet = lerp(displayWet, wetValue, 0.15);
  
  // --- 2. SFONDO REATTIVO ---
  color sfondoNormale = color(30, 30, 30);       
  color sfondoGhiaccio = color(25, 35, 50);
  background(lerpColor(sfondoNormale, sfondoGhiaccio, freezeIntensity));
  
  // --- TESTI DI STATO ---
  fill(255);
  textAlign(LEFT, TOP);
  textSize(12);
  text("Bridge Serial -> OSC", 10, 10);
  text("Vertici (Encoder): " + targetPot, 10, 30);
  text("Potenziometro (Wet): " + wetValue, 10, 50);
  text("Pulsante (Button): " + button, 10, 70);

  // --- CALCOLO TARGET GEOMETRIA ---
  float R = 100;
  float[] targetX = new float[5];
  float[] targetY = new float[5];
  
  // if (targetPot == 1) {
  //   targetX[0] = 0;   targetY[0] = 0;
  //   targetX[1] = 0;   targetY[1] = 0;
  //   targetX[2] = 0;   targetY[2] = 0;
  //   targetX[3] = 0;   targetY[3] = 0;
  // } 
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
    targetX[4] = -R;   targetY[4] = -R;
  }
  else if (targetPot == 4) {
    targetX[0] = 0;   targetY[0] = -R; 
    targetX[1] = R*sin(PI*2/5);   targetY[1] = -R*cos(PI*2/5);  
    targetX[2] = R*sin(PI*4/5);  targetY[2] = -R*cos(PI*4/5);  
    targetX[3] = R*sin(PI*6/5);  targetY[3] = -R*cos(PI*6/5);
    targetX[4] = R*sin(PI*8/5);   targetY[4] = -R*cos(PI*8/5);
  }
  
  boolean inMovimento = false;
  float velocita = 0.15;
  for (int i = 0; i < 5; i++) {
    px[i] = lerp(px[i], targetX[i], velocita);
    py[i] = lerp(py[i], targetY[i], velocita);
    if (dist(px[i], py[i], targetX[i], targetY[i]) > 1.0) {
      inMovimento = true;
    }
  }
  
  int puntiDaDisegnare = max(currentDrawPot, targetPot+1);
  if (!inMovimento) {
    currentDrawPot = targetPot+1;
  }
  
  // --- CONTENUTO 1: LA GEOMETRIA (1/3) ---
  pushMatrix();
  translate(width / 3, height / 2);
  stroke(255, 150); 
  strokeWeight(3);
  noFill();
  
  if (puntiDaDisegnare > 1) {
    beginShape();
    for (int i = 0; i < puntiDaDisegnare; i++) {
      vertex(px[i], py[i]);
    }
    if (puntiDaDisegnare > 2) {
      endShape(CLOSE);
    } else {
      endShape();
    }
  }
  
  for (int i = 0; i < puntiDaDisegnare; i++) {
    noStroke();
    fill(0, 200, 255, 50); 
    ellipse(px[i], py[i], 45, 45); 
    
    fill(0, 200, 255); 
    ellipse(px[i], py[i], 20, 20); 
  }
  popMatrix();

  // --- CONTENUTO 2: WET GAUGE CON ICONA REATTIVA (2/3) ---
  pushMatrix();
  translate(2 * width / 3, height / 2 + 60); 
  int diametro = 240;
  
  // A. Il "Binario" di sfondo
  noFill();
  stroke(0, 150, 255, 30); 
  strokeWeight(10); 
  strokeCap(ROUND);
  arc(0, 0, diametro, diametro, radians(160), radians(380));
  
  // B. La Barra di Progresso azzurra
  angoloProgresso = map(displayWet, 0, 100, radians(160.5), radians(380));
  stroke(0, 200, 255); 
  strokeWeight(14); 
  arc(0, 0, diametro, diametro, radians(160), angoloProgresso);
  
  
  // C. GEOMETRIA CENTRALE (OPACITÀ MASSIMA AL 50% WET)
  float alphaCerchio = 0;
  float alphaLinea   = 0;
  
  if (displayWet <= 50) {
    alphaCerchio = 255;
    alphaLinea   = map(displayWet, 0, 50, 0, 255);
  } else {
    alphaCerchio = map(displayWet, 50, 100, 255, 0);
    alphaLinea   = 255;
  }
  
  float cx = 0;
  float cy = 15;
  float dCerchio = 85;
  
  // 1. Il Cerchio interno vuoto
  if (alphaCerchio > 0.5) {
    noFill();
    stroke(0, 200, 255, alphaCerchio); 
    strokeWeight(5);
    ellipse(cx, cy, dCerchio, dCerchio);
  }
  
  // 2. La Linea Spezzata / Freccia tangente (TUA calibrazione originale)
  if (alphaLinea > 0.5) {
    noFill();
    stroke(0, 200, 255, alphaLinea); 
    strokeWeight(5);
    strokeJoin(ROUND); 
    strokeCap(ROUND);
    
    beginShape();
    vertex(-75, 45);  
    vertex(0, -60);   
    vertex(75, 45);   
    endShape();
  }
  
  // 3. Il Numero fisso al centro del cerchio
  fill(0, 200, 255);
  textAlign(CENTER, CENTER); 
  textSize(32); 
  text(wetValue, cx, cy - 3); 
  
  // Etichetta sotto l'icona
  fill(200);
  textSize(14); 
  text("WET %", 0, 85); 
  
  popMatrix();

  // --- SLOT IN BASSO ---
  // Slot 1 (Sinistra): Tastiera Pianoforte
  pushMatrix();
  translate(80, 460); 
  drawPianoSlot();
  popMatrix();

  // Slot 2 (Centro): Dropdown Tonalità
  pushMatrix();
  translate(420, 500); 
  drawDropdownSlot();
  popMatrix();

  // Slot 3 (Destra): Dropdown Modo
  pushMatrix();
  translate(820, 500); 
  drawModeSlot(currentModes);
  popMatrix();

  // --- DISEGNO EFFETTO FREEZE PERIMETRALE ---
  drawFreezeEffect();
}

void drawFreezeEffect() {
  if (freezeIntensity < 0.01) return; 
  noStroke();
  fill(220, 245, 255, 200 * freezeIntensity); 
  float step = 4; float maxInward = 30 * freezeIntensity; 
  beginShape();
  for (float x = 0; x <= width; x += step) { float n = noise(x * 0.1, iceTime);
  vertex(x, n * maxInward); } vertex(width, 0); vertex(0, 0); endShape(CLOSE);
  beginShape();
  for (float x = 0; x <= width; x += step) { float n = noise(x * 0.1, 500 + iceTime);
  vertex(x, height - (n * maxInward)); } vertex(width, height); vertex(0, height); endShape(CLOSE);
  beginShape();
  for (float y = 0; y <= height; y += step) { float n = noise(y * 0.1, 1000 + iceTime);
  vertex(n * maxInward, y); } vertex(0, height); vertex(0, 0); endShape(CLOSE);
  beginShape();
  for (float y = 0; y <= height; y += step) { float n = noise(y * 0.1, 1500 + iceTime);
  vertex(width - (n * maxInward), y); } vertex(width, height); vertex(width, 0); endShape(CLOSE);
  noFill(); strokeWeight(15);
  for(int i = 0; i < 3; i++) { stroke(255, (15 - i*4) * freezeIntensity); rect(0, 0, width, height);
  }
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
          
          // CONTROLLO ANTISPAM SENSORI: Invia solo se c'è un cambiamento hardware
          if (targetPot != lastArduinoPot || wetValue != lastArduinoWet || button != lastArduinoButton) {
            
            OscMessage myMessage = new OscMessage("/arduino/params");
            myMessage.add(targetPot);
            myMessage.add(wetValue);
            myMessage.add(button);
            
            oscP5.send(myMessage, superColliderDest);
            //oscP5.send(myMessage, juceDest);
            
            // Aggiorna la memoria
            lastArduinoPot = targetPot;
            lastArduinoWet = wetValue;
            lastArduinoButton = button;
            
            // (Opzionale per debug)
            // println("Inviato OSC Sensori: Pot:" + targetPot + " Wet:" + wetValue + " Btn:" + button);
          }
          
          // Chiamiamo sempre la funzione per l'accordo. 
          // Non ti preoccupare: ha già il suo filtro antispam interno!
          sendChordComplexity(); 
        }
      }
    }
  } catch (Exception e) { }
}

void drawPianoSlot() {
  int numTastiBianchi = 8;
  int larghezzaTasto = 22; int altezzaTasto = 80;
  color tastoSpento = color(200);
  color tastoAcceso = color(0, 200, 255); color tastoNeroColor = color(30);
  
  // 1. RECUPERIAMO IL NOME DEL MODO ATTUALE (mostriamo solo Maggiore/Minore)
  String[] currentModes = basicModes;
  int safeModeIndex = (selectedModeIndex >= currentModes.length) ? 0 : selectedModeIndex;
  String mode = currentModes[safeModeIndex];
  
  // 2. CREIAMO IL PATTERN DELLE NOTE DELL'ACCORDO (semitoni rispetto alla fondamentale)
  int[] intervalli = new int[targetPot];
  intervalli[0] = 0; // Fondamentale
  
  if (targetPot >= 2) {
    intervalli[1] = 7; // Quinta giusta
  }
  if (targetPot >= 3) {
    // La terza cambia in base al modo (solo Maggiore/Minore disponibili)
    if (mode.equals("Minore")) {
      intervalli[2] = 3; // Terza Minore
    } else {
      intervalli[2] = 4; // Terza Maggiore
    }
  }
  if (targetPot == 4) {
    // Gestione della settima: con menu limitato a Maggiore/Minore,
    // assumiamo Maggiore -> settima maggiore, Minore -> settima minore
    if (mode.equals("Maggiore")) {
      intervalli[3] = 11; // Settima Maggiore
    } else {
      intervalli[3] = 10; // Settima Minore (per "Minore")
    }
  }

  // Mappatura tasti bianchi (Do base = 0)
  int[] notaTastoBianco = {0, 2, 4, 5, 7, 9, 11, 12}; 

  // 3. DISEGNO DEI TASTI BIANCHI (Ancorati a Do = 0 come riferimento fisso)
  stroke(50); strokeWeight(2);
  for (int i = 0; i < numTastiBianchi; i++) {
    int notaMidiTasto = notaTastoBianco[i];
    
    boolean notaAccesa = false;
    for (int j = 0; j < intervalli.length; j++) {
      // Sostituito selectedKeyIndex con 0 per bloccare la visualizzazione sul Do
      if ((0 + intervalli[j]) % 12 == notaMidiTasto % 12) {
        if (notaMidiTasto < 12 || (0 + intervalli[j]) >= 12) {
          notaAccesa = true;
        }
      }
    }
    
    if (notaAccesa) fill(tastoAcceso);
    else fill(tastoSpento);
    
    rect(i * larghezzaTasto, 0, larghezzaTasto, altezzaTasto, 0, 0, 3, 3);
  }

  // 4. DISEGNO DEI TASTI NERI (Ancorati a Do = 0 come riferimento fisso)
  int larghezzaNero = 12; int altezzaNero = 45;
  int[] notaTastoNero = {1, 3, -1, 6, 8, 10, -1}; 

  for (int i = 0; i < numTastiBianchi - 1; i++) {
    if (notaTastoNero[i] != -1) {
      int notaMidiNero = notaTastoNero[i];
      float xNero = (i * larghezzaTasto) + larghezzaTasto - (larghezzaNero / 2.0);
      
      boolean neroAcceso = false;
      for (int j = 0; j < intervalli.length; j++) {
        // Sostituito selectedKeyIndex con 0 per bloccare la visualizzazione sul Do
        if ((0 + intervalli[j]) % 12 == notaMidiNero) {
          neroAcceso = true;
        }
      }
      
      if (neroAcceso) fill(tastoAcceso);
      else fill(tastoNeroColor);
      
      stroke(50); strokeWeight(1);
      rect(xNero, 0, larghezzaNero, altezzaNero, 0, 0, 2, 2);
    }
  }

  // 5. TESTO DELL'ACCORDO IN BASSO (Mostra il nome effettivo dell'accordo selezionato)
  fill(200); textAlign(CENTER, TOP); textSize(14);
  float centroTastiera = (numTastiBianchi * larghezzaTasto) / 2.0;
  String root = keys[selectedKeyIndex];
  String nomeAccordo = "";
  
  if (targetPot == 1) nomeAccordo = "ROOT (" + root + ")";
  else if (targetPot == 2) nomeAccordo = "POWER (" + root + "5)";
  else if (targetPot == 3) {
    String suff = mode.equals("Minore") ? "min" : "maj";
    nomeAccordo = "TRIAD (" + root + suff + ")";
  }
  else if (targetPot == 4) {
    String suff = mode.equals("Minore") ? "m7" : "maj7";
    nomeAccordo = "SEVENTH (" + root + suff + ")";
  }
  text(nomeAccordo, centroTastiera, altezzaTasto + 15);
}
// RILETTURA DI DISEGNO CORRETTA (Senza blocchi mouse duplicati all'interno)
void drawDropdownSlot() {
  int w = 120; int h = 30;
  fill(200); textAlign(CENTER, BOTTOM); textSize(12); text("TONALITÀ", w/2, -8);
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
  text("MODO", w/2, -8);
  if (modeDropdownOpen) {
    int itemH = 25; int totalH = currentModes.length * itemH;
    for (int i = 0; i < currentModes.length; i++) {
      int itemY = -totalH + (i * itemH);
      float mX = mouseX - 820; float mY = mouseY - 500;
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

// GESTIONE UNICA DEI CLIC (Invia i dati OSC al rilascio o cambio selezione)
void mousePressed() {
  int s2X = 420, s2Y = 500, w = 120, h = 30;
  int s3X = 820, s3Y = 500;
  
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
    int itemH = 25; int totalH = currentModes.length * itemH;
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

// FUNZIONE OSC COMPLESSITÀ ACCORDI (Con logica Antispam basata sulle stringhe)
void sendChordComplexity() {
  String[] currentModes = basicModes;
  int safeModeIndex = (selectedModeIndex >= currentModes.length) ? 0 : selectedModeIndex;

  String currentRoot = keys[selectedKeyIndex];
  String currentMode = currentModes[safeModeIndex];
  
  // CONTROLLO: Invia solo se la parola della nota o la parola del modo sono cambiate
  if (!currentRoot.equals(lastSentRoot) || !currentMode.equals(lastSentMode)) {
    
    OscMessage chordMsg = new OscMessage("/chord/complexity");
    chordMsg.add(currentRoot); 
    chordMsg.add(currentMode);
    
    oscP5.send(chordMsg, superColliderDest);
    
    // Aggiorna la memoria con le nuove parole
    lastSentRoot = currentRoot;
    lastSentMode = currentMode;
  }
}
