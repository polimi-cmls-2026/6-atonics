(
s.options.memSize = 65536;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 2;
// Inserisci qui i tuoi dispositivi audio virtuali corretti
s.options.inDevice = "Windows WASAPI : VoiceMeeter Aux Output (VB-Audio VoiceMeeter AUX VAIO)";
s.options.outDevice = "Windows WASAPI : Altoparlanti (Conexant SmartAudio HD)";
s.boot;

s.waitForBoot({
    "Inizializzazione Logica Diatonica e DSP...".postln;

    // --- VARIABILI DI STATO ---
    ~rootFreq = 440;
    ~vocalPitch = 440;
    ~complexity = 2;         
    ~tonicMidi = 60;         
    ~scaleMode = 0;     
    ~sourceSelect = 1;
    ~gain = 0.5;

    // --- STRUTTURE DATI ARMONICHE (INTATTE) ---
    ~getScale = { arg mode = 0;
        if(mode.asInteger == 1, { [0, 2, 3, 5, 7, 8, 10] }, { [0, 2, 4, 5, 7, 9, 11] })
    };

    ~getNearestScaleNote = { arg midiNote, tonic, mode;
        var scale = ~getScale.value(mode);
        var inputMidi = midiNote.round.asInteger;
        var baseOctave = ((inputMidi - tonic) / 12).floor.asInteger;
        var bestDist = 1000, nearestMidi = inputMidi, nearestDegree = 0, nearestOctave = baseOctave;
        
        [-1, 0, 1].do({ arg octCorr;
            scale.do({ arg semitone, degIdx;
                var candOctave = baseOctave + octCorr;
                var candMidi = tonic + (12 * candOctave) + semitone;
                var candDist = (candMidi - inputMidi).abs;
                if(candDist < bestDist, {
                    bestDist = candDist;
                    nearestMidi = candMidi; nearestDegree = degIdx; nearestOctave = candOctave;
                });
            });
        });
        [nearestMidi, nearestDegree, nearestOctave]
    };

    ~getDiatonicMidiNote = { arg tonic, mode, degree, octave;
        var scale = ~getScale.value(mode);
        var scaleSize = scale.size;
        var octCorr = (degree / scaleSize).floor.asInteger;
        var wrappedDegree = degree % scaleSize;
        (tonic + (12 * (octave + octCorr)) + scale.at(wrappedDegree))
    };

    ~getChordFreqs = { arg root, complexity, tonic, mode, vocalPitch;
        var rootMidi = root.max(20).cpsmidi.round.asInteger;
        var noteInfo = ~getNearestScaleNote.value(rootMidi, tonic, mode);
        var rMidi = noteInfo[0], rDegree = noteInfo[1], rOctave = noteInfo[2];
        var vocalMidi = vocalPitch.max(20).cpsmidi;
        var chordMidi;
        
        var degreeSteps = switch(complexity.asInteger.clip(1, 4),
            1, { [0, 4] },             
            2, { [0, 2, 4] },          
            3, { [0, 2, 4, 6] }, 
            4, { [0, 2, 4, 6, 8] }     
        );
        
        chordMidi = degreeSteps.collect({ arg step;
            ~getDiatonicMidiNote.value(tonic, mode, rDegree + step, rOctave)
        });
        
        chordMidi = chordMidi.collect({ arg targetNote;
            var octaves = [-2, -1, 0, 1, 2];
            var bestNote = targetNote;
            var minDistance = 1000;

            octaves.do({ arg oct;
                var candidate = targetNote + (oct * 12);
                var distance = (candidate - vocalMidi).abs;
                if(distance < minDistance) {
                    minDistance = distance;
                    bestNote = candidate;
                };
            });
            bestNote
        });
        chordMidi.midicps.extend(6, 0)
    };

    // --- SYNTHDEF MODIFICATA: SOURCE-FILTER MODEL ALTA RISOLUZIONE ---
    SynthDef(\trueHarmonizer, {
        arg vocalPitch = 440, freqs = #[440, 554, 659, 0, 0, 0], amp = 0.5, gate = 1, vocalIn = 0, mix = 1.0;

        var dryVoice, smoothFreqs;
        var carrier, breath, harmonies, sigHarmonies, finalSig;
        var numBands = 48; // Portiamo a 48 bande per una scansione precisissima delle formanti vocali
        var bandFreqs;

        dryVoice = SoundIn.ar(vocalIn);

        // 1. SMOOTHING
        smoothFreqs = Lag.kr(freqs.max(1), 0.05);

        // --- INIZIO: SOURCE-FILTER MODEL ---

        // 2. LA SORGENTE (Il "Pitch" puro per l'accordo)
        // Blip genera un impulso limitato in banda, che matematicamente è la forma d'onda più simile 
        // alla vibrazione della glottide umana (ricchissima di armoniche).
        carrier = smoothFreqs.collect({ |f, i|
            var voiceSource = Blip.ar(f.max(50), 20000 / f.max(50));
            voiceSource * (f > 0); // Disattiva se lo slot dell'array frequenze è vuoto (0)
        }).sum;

        // Recuperiamo il "rumore" ad alta frequenza dalla voce originale (essenziale per "S", "F", "T").
        // Lo estraiamo con un filtro passa-alto e lo applichiamo a del PinkNoise.
        breath = PinkNoise.ar(0.3) * Amplitude.ar(HPF.ar(dryVoice, 3000), 0.005, 0.05);
        carrier = carrier + breath;

        // 3. IL FILTRO (Le "Formanti" della tua voce)
        // Creiamo una scala esponenziale di 48 frequenze da 80 Hz a 12000 Hz
        bandFreqs = (1..numBands).collect({ |i| i.linexp(1, numBands, 80, 12000) });

        harmonies = bandFreqs.collect({ |f|
            var modBand, carBand, env;

            // Analizziamo quanta energia c'è in questa specifica banda nella TUA voce
            modBand = BPF.ar(dryVoice, f, 0.15); // rq 0.15 definisce maglie molto strette per isolare la formante
            
            // Lavoriamo ad audio-rate (.ar) sull'Amplitude follower per non avere latenza di controllo sui transienti
            env = Amplitude.ar(modBand, 0.005, 0.05);

            // Imprimiamo quello stesso inviluppo sulla corrispettiva banda della sorgente sintetica
            carBand = BPF.ar(carrier, f, 0.15);
            carBand * env;
        }).sum;

        // Compensazione per la perdita di inserzione data dai filtri passabanda
        harmonies = harmonies * 15.0;

        // --- FINE: SOURCE-FILTER MODEL ---

        // 4. EFFETTI E SPAZIALIZZAZIONE
        // Allarghiamo l'immagine dell'armonia ai lati tramite effetto Haas
        sigHarmonies = DelayN.ar(harmonies, 0.1, [0.02, 0.035]);

        sigHarmonies = FreeVerb.ar(sigHarmonies, mix: 0.4, room: 0.7, damp: 0.5);
        sigHarmonies = Limiter.ar(sigHarmonies * 3.0, 0.95, 0.01);

        // 5. MIX FINALE
        finalSig = dryVoice + (sigHarmonies * mix);
        finalSig = finalSig * amp * EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);

        Out.ar(0, finalSig ! 2);
    }).add;
    s.sync;

    // --- RICEVITORI OSC (INTATTI) ---
    OSCdef.freeAll;
    
    OSCdef(\vocalPitch, { |msg|
        ~vocalPitch = msg[1];
        if(~sourceSelect == 0) {
            ~rootFreq = msg[1];
            if(~activeSynth.notNil) {
                ~activeSynth.set(\vocalPitch, ~vocalPitch, \freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
            }
        } {
            if(~activeSynth.notNil) { ~activeSynth.set(\vocalPitch, ~vocalPitch); }
        };
    }, '/vocalPitch');
    
    OSCdef(\guitarPitch, { |msg|
        if(~sourceSelect == 1) {
            ~rootFreq = msg[1];
            if(~activeSynth.notNil) {
                ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
            }
        }
    }, '/guitarPitch');
    
    OSCdef(\sourceSelect, { |msg| ~sourceSelect = msg[1]; }, '/sourceSelect');

    OSCdef(\joystick, { |msg|
        ~gain = msg[1].linlin(0, 1023, 0.0, 1.0).lag(0.1);
        ~complexity = msg[2].linlin(0, 1023, 1, 4).round; 
        if(~activeSynth.notNil) {
            ~activeSynth.set(\amp, ~gain, \freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/joystick');
    
    OSCdef(\potenziometro, { |msg|
        if(~activeSynth.notNil) { ~activeSynth.set(\mix, msg[1].linlin(0, 1023, 0.0, 1.0).lag(0.05)); }
    }, '/potenziometro');
    
    OSCdef(\freeze, { |msg|
        var isFrozen = msg[1].asInteger;
        "Comando Freeze ricevuto: %".format(isFrozen).postln;
    }, '/freeze');
    
    OSCdef(\tonic, { |msg|
        ~tonicMidi = msg[1].asInteger;
        "Nuova Tonica: %".format(~tonicMidi).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/tonic');
    
    OSCdef(\mode, { |msg|
        ~scaleMode = msg[1].asInteger;
        "Nuovo Modo: %".format(~scaleMode).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/mode');
    
    // --- AVVIO DEL SISTEMA ---
    if(~activeSynth.notNil) { ~activeSynth.free };
    ~activeSynth = Synth(\trueHarmonizer, [\freqs, ~getChordFreqs.value(440, ~complexity, ~tonicMidi, ~scaleMode, 440), \amp, 0.5]);

    "=============================".postln;
    "SISTEMA PRONTO E IN ASCOLTO".postln;
    "=============================".postln;
});
)
