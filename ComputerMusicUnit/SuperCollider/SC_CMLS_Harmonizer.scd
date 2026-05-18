(
// 1. Configurazione Server
s.options.numOutputBusChannels = 2; // Uscita verso le casse reali
s.options.numInputBusChannels = 2;  // Ingresso dal cavo virtuale

s.options.inDevice = "Windows WASAPI : VoiceMeeter Aux Output (VB-Audio VoiceMeeter AUX VAIO)";
s.options.outDevice = "Windows WASAPI : Altoparlanti (Conexant SmartAudio HD)";

s.boot;
)

(
// 2. Variabili di Stato (AGGIORNATO con ~vocalPitch)
~rootFreq = 440;       // Frequenza fondamentale dell'accordo
~vocalPitch = 440;     // <-- MODIFICA: Memorizza l'ultimo pitch reale della voce per il PitchShift
~complexity = 1;       // Da 1 a 5 (controllata da Joystick asse Y)
~gain = 0.5;           // Volume (controllato da Joystick asse X)
~sourceSelect = 1;     // IMPOSTATO A 1: abilita la ricezione da /guitarPitch
~activeSynth = nil;    // Per gestire il nodo del sintetizzatore
)

(
// Libera eventuali ricevitori precedenti per evitare doppioni
OSCdef.freeAll;

// Crea un ascoltatore solo per la voce
OSCdef(\testVoce, { |msg|
    var pitch = msg[1];
    ("VOCE QUANTIZZATA RICEVUTA: " ++ pitch.round(0.01) ++ " Hz").postln;
}, '/vocalPitch');

// Crea un ascoltatore per la chitarra (per confronto)
OSCdef(\testChitarra, { |msg|
    var pitch = msg[1];
    ("CHITARRA RICEVUTA: " ++ pitch.round(0.01) ++ " Hz").postln;
}, '/guitarPitch');

"In ascolto su OSC...".postln;
)


(
SynthDef(\trueHarmonizer, {
    arg vocalPitch = 440, freqs = #[440, 554, 659, 0, 0, 0], amp = 0.5, gate = 1, vocalIn = 0, mix = 0.5;

    var dryVoice, harmonies, pitchRatios, safeVocalPitch, sigHarmonies, finalSig;

    // Ingresso microfono reale (Mono)
    dryVoice = SoundIn.ar(vocalIn);

    safeVocalPitch = vocalPitch.max(70);
    pitchRatios = freqs / safeVocalPitch;

    // Creazione delle voci armonizzate
    harmonies = pitchRatios.collect({ |ratio, i|
        var shifted;
        
        shifted = PitchShift.ar(
            in: dryVoice,
            windowSize: 0.03, 
            pitchRatio: ratio,
            pitchDispersion: 0.0, 
            timeDispersion: 0.005 
        );

        // Applichiamo un Filtro Passa-Basso per ammorbidire l'effetto "Chipmunk" sulle armonie
        shifted = LPF.ar(shifted, 4500);

        shifted * (freqs[i] > 0);
    });

    // SPAZIALIZZAZIONE: invece di .sum, Splay distribuisce le armonie in stereo
    sigHarmonies = Splay.ar(harmonies);
    
    // Crossfade: la dryVoice deve essere "sdoppiata" in stereo per il mix
    finalSig = XFade2.ar(dryVoice ! 2, sigHarmonies, mix * 2 - 1);
    
    // RIVERBERO: Aggiunge profondità e amalgama voce e armonie
    finalSig = FreeVerb.ar(finalSig, mix: 0.25, room: 0.6, damp: 0.5);

    // Inviluppo generale e uscita
    finalSig = finalSig * amp * EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);
    
    Out.ar(0, finalSig); // Niente Pan2 qui, finalSig è già stereo grazie a Splay
}).add;
)


(
// Funzione per calcolare le note dell'accordo in base alla complessità
~getChordFreqs = { |root, complexity|
    var semitones;
    semitones = switch (complexity.asInteger,
        1, { [0, 7] },             // Quinta (Power chord)
        2, { [0, 4, 7] },          // Triade Maggiore
        3, { [0, 4, 7, 11] },       // Maj7
        4, { [0, 4, 7, 11, 14] },   // Maj9
        5, { [0, 4, 7, 11, 14, 17] },// 13th (Complessità massima)
        { [0, 7] }
    );
    (root.cpsmidi + semitones).midicps.extend(6, 0); // Converte in Hz e riempie l'array a 6
};

// --- RICEVITORI OSC AGGIORNATI ---

// 1. Pitch dalla Voce (da JUCE)
OSCFunc({ |msg|
    ~vocalPitch = msg[1]; // <-- MODIFICA: Salva SEMPRE l'intonazione vocale per aggiornare il Pitch Shifter

    if(~sourceSelect == 0) {
        // Se la voce guida l'armonia, aggiorna anche la rootFreq
        ~rootFreq = msg[1]; 
        if(~activeSynth.notNil) {
            ~activeSynth.set(\vocalPitch, ~vocalPitch, \freqs, ~getChordFreqs.(~rootFreq, ~complexity));
        }
    } {
        // Se la chitarra guida l'armonia, aggiorna comunque il vocalPitch dentro al Synth attivo!
        if(~activeSynth.notNil) {
            ~activeSynth.set(\vocalPitch, ~vocalPitch);
        }
    };
}, '/vocalPitch');

// 2. Pitch dalla Chitarra (da JUCE)
OSCFunc({ |msg|
    if(~sourceSelect == 1) {
        ~rootFreq = msg[1]; // La chitarra detta l'accordo
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.(~rootFreq, ~complexity));
        }
    }
}, '/guitarPitch');

// 3. Selezione Sorgente (On/Off Chitarra)
OSCFunc({ |msg|
    ~sourceSelect = msg[1];
    "Sorgente cambiata a: %".format(if(~sourceSelect==0, {"VOCE"}, {"CHITARRA"})).postln;
}, '/sourceSelect');

// 4. Joystick (Arduino)
OSCFunc({ |msg|
    // asse X (msg[1]) -> Gain (mappato 0-1023 a 0.0-1.0)
    ~gain = msg[1].linlin(0, 1023, 0.0, 1.0).lag(0.1);

    // asse Y (msg[2]) -> Complessità (mappato 0-1023 a 1-5)
    ~complexity = msg[2].linlin(0, 1023, 1, 5).round;

    ~activeSynth.set(\amp, ~gain);
    ~activeSynth.set(\freqs, ~getChordFreqs.(~rootFreq, ~complexity));
}, '/joystick');
)

/*
(
// Inizia a suonare (AGGIORNATO con il nome del nuovo Synth \trueHarmonizer)
~activeSynth = Synth(\trueHarmonizer, [\freqs, ~getChordFreqs.(440, 1), \amp, 0.5]);

// Funzione di test ciclico
Routine({
    loop {
        "Test: Cambio Nota e Complessità".postln;
        ~rootFreq = [440, 329, 349, 392].choose; // Note casuali (La, Mi, Fa, Sol)
        ~complexity = (1..5).choose;

        ~activeSynth.set(\freqs, ~getChordFreqs.(~rootFreq, ~complexity));
        ~activeSynth.set(\amp, 0.4);

        2.wait;
    }
}).play;
)
*/

// Per fermare tutto:
// ~activeSynth.free;

ServerOptions.devices.do({ |dev| dev.postln });
