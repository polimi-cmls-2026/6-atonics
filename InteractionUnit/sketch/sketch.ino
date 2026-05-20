#include <Encoder.h>

// --- SENSORI E PIN ---
Encoder myEnc(2, 3);
const int buttonPin = 4;
const int joyXPin = A0; // Pin analogico per asse X del Joystick
const int joyYPin = A1; // Pin analogico per asse Y del Joystick

// --- VARIABILI JOYPAD (FORME 1-4) ---
int joyState = 1; // Parte dalla forma 1 (Punto)
int sogliaAlta = 800; // Oltre questo valore il joypad è "premuto" in un verso
int sogliaBassa = 200; // Sotto questo valore è "premuto" nel verso opposto

// --- VARIABILI ENCODER (WET 0-100) ---
long oldPosition = 0;
int wetValue = 0; // Parte da zero

// --- VARIABILI PULSANTE (SWITCH FREEZE) ---
int toggleState = 0;
int lastButtonState = LOW;


void setup() {
  Serial.begin(115200); 
  pinMode(buttonPin, INPUT); 
}

void loop() {
  
  // ------------------------------------
  // 1. GESTIONE JOYPAD (Forme da 1 a 4)
  // ------------------------------------
  int xVal = analogRead(joyXPin);
  int yVal = analogRead(joyYPin);

  if (yVal > sogliaAlta) {
    joyState = 4; // SU
  } 
  else if (xVal > sogliaAlta) {
    joyState = 3; // DESTRA
  } 
  else if (yVal < sogliaBassa) {
    joyState = 2; // GIÙ
  } 
  else if (xVal < sogliaBassa) {
    joyState = 1; // SINISTRA
  }


  // ------------------------------------
  // 2. GESTIONE ENCODER (Valore WET 0-100)
  // ------------------------------------
  long newPosition = myEnc.read();
  
  // Ad ogni singolo scatto fisso (+1 o -1), incrementa/decrementa di 4
  if (newPosition >= oldPosition + 1) {
    wetValue = wetValue - 4; // Modificato da -3 a -4             
    oldPosition = newPosition; 
  } else if (newPosition <= oldPosition - 1) {
    wetValue = wetValue + 4; // Modificato da +3 a +4             
    oldPosition = newPosition; 
  }
  
  // Blocchiamo il valore tra 0 e 100
  if (wetValue > 100) wetValue = 100;
  if (wetValue < 0) wetValue = 0;


  // ------------------------------------
  // 3. GESTIONE PULSANTE (SWITCH FREEZE)
  // ------------------------------------
  int currentButtonState = digitalRead(buttonPin);
  if (currentButtonState == HIGH && lastButtonState == LOW) {
    toggleState = !toggleState; 
  }
  lastButtonState = currentButtonState;


  // ------------------------------------
  // 4. INVIO DATI SERIALI
  // ------------------------------------
  Serial.print("DATA,");
  Serial.print(joyState);    
  Serial.print(",");
  Serial.print(wetValue);    
  Serial.print(",");
  Serial.println(toggleState); 

  delay(20); 
}