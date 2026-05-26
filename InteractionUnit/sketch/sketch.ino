#include <Encoder.h>

Encoder myEnc(2, 3);
const int buttonPin = 4;
const int joyXPin = A0; 
const int joyYPin = A1; 

int joyState = 1; 
int sogliaAlta = 800; 
int sogliaBassa = 200; 

long oldPosition = 0;
int wetValue = 0; 

int toggleState = 0;
int lastButtonState = LOW;


void setup() {
  Serial.begin(115200); 
  pinMode(buttonPin, INPUT); 
}

void loop() {
  

  int xVal = analogRead(joyXPin);
  int yVal = analogRead(joyYPin);

  if (yVal > sogliaAlta) {
    joyState = 4; // up
  } 
  else if (xVal > sogliaAlta) {
    joyState = 3; // right
  } 
  else if (yVal < sogliaBassa) {
    joyState = 2; // down
  } 
  else if (xVal < sogliaBassa) {
    joyState = 1; // left
  }



  long newPosition = myEnc.read();
  

  if (newPosition >= oldPosition + 1) {
    wetValue = wetValue - 4;       
    oldPosition = newPosition; 
  } else if (newPosition <= oldPosition - 1) {
    wetValue = wetValue + 4;         
    oldPosition = newPosition; 
  }
  
  if (wetValue > 100) wetValue = 100;
  if (wetValue < 0) wetValue = 0;


  int currentButtonState = digitalRead(buttonPin);
  if (currentButtonState == HIGH && lastButtonState == LOW) {
    toggleState = !toggleState; 
  }
  lastButtonState = currentButtonState;



  Serial.print("DATA,");
  Serial.print(joyState);    
  Serial.print(",");
  Serial.print(wetValue);    
  Serial.print(",");
  Serial.println(toggleState); 

  delay(20); 
}