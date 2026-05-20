(
s.options.memSize = 65536;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 2;
s.options.inDevice = "Windows WASAPI : VoiceMeeter Aux Output (VB-Audio VoiceMeeter AUX VAIO)";
s.options.outDevice = "Windows WASAPI : Altoparlanti (Conexant SmartAudio HD)";
s.boot;

s.waitForBoot({
    "Inizializzazione Logica Diatonica e DSP...".postln;

    // --- VARIABILI DI STATO ---
    ~rootFreq = 440;
    ~vocalPitch = 440;
    ~complexity = 2;         // Default: Triade
    ~tonicMidi = 60;         // 60 = Do
    ~scaleMode = 0;          // 0 = Maggiore, 1 = Minore Naturale
    ~sourceSelect = 1;
    ~gain = 0.5;

    // --- STRUTTURE DATI ARMONICHE ---
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

    // --- FUNZIONE DI CALCOLO ACCORDO (VOCAL ANCHORING) ---
    ~getChordFreqs = { arg root, complexity, tonic, mode, vocalPitch;
        var rootMidi = root.max(20).cpsmidi.round.asInteger;
        var noteInfo = ~getNearestScaleNote.value(rootMidi, tonic, mode);
        var rMidi = noteInfo[0], rDegree = noteInfo[1], rOctave = noteInfo[2];

        // Conversione della nota vocale per l'ancoraggio
        var vocalMidi = vocalPitch.max(20).cpsmidi;
        var chordMidi;

        // AGGIORNATO: 4 Livelli di complessità
        var degreeSteps = switch(complexity.asInteger.clip(1, 4),
            1, { [0, 4] },             // Power Chord (Fondamentale, Quinta)
            2, { [0, 2, 4] },          // Triade (Fond., Terza, Quinta)
            3, { [0, 2, 4, 6] },       // Quadriade (Fond., Terza, Quinta, Settima)
            4, { [0, 2, 4, 6, 8] }     // Nona (Fond., Terza, Quinta, Settima, Nona)
        );

        // Genera gradi diatonici
        chordMidi = degreeSteps.collect({ arg step;
            ~getDiatonicMidiNote.value(tonic, mode, rDegree + step, rOctave)
        });

        // Applica l'ottimizzazione della distanza sulla voce
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

    // --- SYNTHDEF ---
    SynthDef(\trueHarmonizer, {
        arg vocalPitch = 440, freqs = #[440, 554, 659, 0, 0, 0], amp = 0.5, gate = 1, vocalIn = 0, mix = 1.0;

        // DICHIARAZIONE VARIABILI: Tutte rigorosamente in cima
        var dryVoice, harmonies, pitchRatios, safeVocalPitch, sigHarmonies, finalSig, smoothFreqs;

        dryVoice = SoundIn.ar(vocalIn);

        // 1. SMOOTHING: Applichiamo il Lag ai segnali di controllo in ingresso
        safeVocalPitch = Lag.kr(vocalPitch.max(70), 0.05);
        smoothFreqs = Lag.kr(freqs.max(1), 0.05); // Assegnazione senza "var"

        pitchRatios = smoothFreqs / safeVocalPitch;

        harmonies = pitchRatios.collect({ |ratio, i|
            var shifted = PitchShift.ar(dryVoice, 0.1, ratio, 0.0, 0.005);
            shifted = LPF.ar(shifted, 4500); // Taglia le frequenze metalliche del pitch shifter
            shifted * (smoothFreqs[i] > 0);
        });

        // Creiamo un'immagine stereo spalmandola ai lati
        sigHarmonies = Splay.ar(harmonies, levelComp: false);

        // 3. FX SEPARATI: Ritardo asimmetrico per l'effetto Haas (coro largo)
        sigHarmonies = DelayN.ar(sigHarmonies, 0.1, [0.02, 0.035]);
        // Riverbero applicato SOLO alle armonie
        sigHarmonies = FreeVerb.ar(sigHarmonies, mix: 0.4, room: 0.7, damp: 0.5);

        // Limiter di sicurezza
        sigHarmonies = Limiter.ar(sigHarmonies * 3.0, 0.95, 0.01);

        // 2. MIX DRY/WET: La voce dry resta intatta, si aggiungono le armonie dosate dal mix
        finalSig = dryVoice + (sigHarmonies * mix);

        finalSig = finalSig * amp * EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);

        // Uscita forzata in stereo
        Out.ar(0, finalSig ! 2);
    }).add;
    s.sync; // Attende il completamento della compilazione del Synth

    // --- RICEVITORI OSC ---
    OSCdef.freeAll;

    // Pitch da JUCE
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

    // Hardware: Joystick da Arduino
    OSCdef(\joystick, { |msg|
        ~gain = msg[1].linlin(0, 1023, 0.0, 1.0).lag(0.1);
        ~complexity = msg[2].linlin(0, 1023, 1, 4).round; // Scalato per i 4 livelli (Power -> Nona)
        if(~activeSynth.notNil) {
            ~activeSynth.set(\amp, ~gain, \freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/joystick');

    // Hardware: Potenziometro da Arduino
    OSCdef(\potenziometro, { |msg|
        if(~activeSynth.notNil) { ~activeSynth.set(\mix, msg[1].linlin(0, 1023, 0.0, 1.0).lag(0.05)); }
    }, '/potenziometro');

    // Hardware: Footswitch da Arduino
    OSCdef(\freeze, { |msg|
        var isFrozen = msg[1].asInteger;
        "Comando Freeze ricevuto: %".format(isFrozen).postln;
        // La logica del freeze andrà agganciata qui
    }, '/freeze');

    // GUI: Imposta la nota fondamentale da Processing
    OSCdef(\tonic, { |msg|
        ~tonicMidi = msg[1].asInteger;
        "Nuova Tonica: %".format(~tonicMidi).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/tonic');

    // GUI: Imposta il modo da Processing (es. 0 = Maggiore, 1 = Minore)
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