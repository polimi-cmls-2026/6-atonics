(
s.options.memSize = 65536;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 2;

// Forza l'uso dell'ASIO virtuale di VoiceMeeter (assicurati del nome esatto sul tuo PC)
s.options.device = "ASIO : Voicemeeter AUX Virtual ASIO";
s.options.sampleRate = 44100;
s.boot;

s.waitForBoot({
    "Inizializzazione Logica Diatonica e DSP (Definitive Edition)...".postln;

    // --- VARIABILI DI STATO ---
    ~rootFreq = 440;
    ~vocalPitch = 440;
    ~complexity = 2;         // Default: Triade
    ~tonicMidi = 60;         // 60 = Do
    ~scaleMode = 0;          // 0 = Maggiore, 1 = Minore Naturale
    ~sourceSelect = 1;       // 1 = Guitar-based, 0 = Voice-based
    ~gain = 0.5;
    ~isFrozen = 0;           // Pedale disattivato di default

    // --- STRUTTURE DATI ARMONICHE ---
    ~getScale = { arg mode = 0;
        if(mode.asInteger == 1, { [0, 2, 3, 5, 7, 8, 10] }, { [0, 2, 4, 5, 7, 9, 11] })
    };

    ~getNearestScaleNote = { arg midiNote, tonic, mode, forceUp = false;
        var scale = ~getScale.value(mode);
        var inputMidi = midiNote.round.asInteger;
        var baseOctave = ((inputMidi - tonic) / 12).floor.asInteger;
        var bestDist = 1000, nearestMidi = inputMidi, nearestDegree = 0, nearestOctave = baseOctave;

        if(forceUp, {
            // LOGICA VOCE: Cerca la prima nota diatonica MAGGIORE o UGUALE alla nota cantata (Shift Up)
            var found = false;
            [0, 1].do({ arg octCorr;
                if(found.not, {
                    scale.do({ arg semitone, degIdx;
                        var candOctave = baseOctave + octCorr;
                        var candMidi = tonic + (12 * candOctave) + semitone;
                        if((candMidi >= inputMidi) && found.not, {
                            nearestMidi = candMidi;
                            nearestDegree = degIdx;
                            nearestOctave = candOctave;
                            found = true;
                        });
                    });
                });
            });
        }, {
            // LOGICA CHITARRA: Cerca la nota con la distanza assoluta minore
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

    // --- FUNZIONE DI CALCOLO ACCORDO (CON CERVELLO ARMONICO AVANZATO) ---
    ~getChordFreqs = { arg root, complexity, tonic, mode, vocalPitch;
        var rootMidi = root.max(20).cpsmidi.round.asInteger;
        var isVoiceDriving = (~sourceSelect == 0);

        var noteInfo = ~getNearestScaleNote.value(rootMidi, tonic, mode, isVoiceDriving);
        var rMidi = noteInfo[0], rDegree = noteInfo[1], rOctave = noteInfo[2];

        var vocalMidi = vocalPitch.max(20).cpsmidi;
        var chordMidi;

        var degreeSteps = switch(complexity.asInteger.clip(1, 4),
            1, { [0, 4] },             // Power Chord
            2, { [0, 2, 4] },          // Triade
            3, { [0, 2, 4, 6] },       // Quadriade/Settima
            4, { [0, 2, 4, 6, 8] }     // Nona
        );

        // Genera gradi diatonici con regole Jazz (Avoid Notes b9) e Dominante Minore
        chordMidi = degreeSteps.collect({ arg step;
            var noteMidi;
            var actualStep = step;

            // Gestione della Nona
            if(step == 8, {
                if(mode.asInteger == 0, { // MAGGIORE
                    if(rDegree == 2, { actualStep = 10; });
                    if(rDegree == 6, { actualStep = 12; });
                }, { // MINORE
                    if(rDegree == 1, { actualStep = 12; });
                    if(rDegree == 4, { actualStep = 12; });
                });
            });

            noteMidi = ~getDiatonicMidiNote.value(tonic, mode, rDegree + actualStep, rOctave);

            // Sensibile in minore sul 5° grado
            if((mode.asInteger == 1) && (rDegree == 4) && (actualStep == 2), {
                noteMidi = noteMidi + 1;
            });

            noteMidi;
        });

        // Applica il Vocal Anchoring
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

    // --- SYNTHDEF (CON DSP SICURO E ANTI-GLITCH) ---
    SynthDef(\trueHarmonizer, {
        arg vocalPitch = 440, freqs = #[440, 554, 659, 0, 0, 0], amp = 0.5, gate = 1, vocalIn = 0, mix = 1.0;

        var dryVoice, harmonies, safeVocalPitch, sigHarmonies, finalSig, smoothFreqs;
        var voiceGates, pitchRatios, fxSignal;

        dryVoice = SoundIn.ar(vocalIn);

        // Smoothing dei segnali
        safeVocalPitch = Lag.kr(vocalPitch.max(70), 0.05);
        smoothFreqs = Lag.kr(freqs.max(1), 0.05);

        // Array di gate (impedisce calcoli su voci vuote estese a 0Hz)
        voiceGates = Lag.kr(freqs > 0, 0.05);
        pitchRatios = smoothFreqs / safeVocalPitch;

        harmonies = pitchRatios.collect({ |ratio, i|
            // Previene divisioni/rapporti pericolosi
            var safeRatio = Select.kr(freqs[i] > 0, [1.0, ratio]);

            var shifted = PitchShift.ar(dryVoice, 0.1, safeRatio, 0.0, 0.005);
            shifted = LPF.ar(shifted, 4500);

            shifted * voiceGates[i];
        });

        sigHarmonies = Splay.ar(harmonies, levelComp: false);

        // --- INIZIO MODIFICA FX IN PARALLELO ---

        // 1. Creiamo un ramo parallelo per gli effetti
        fxSignal = DelayN.ar(sigHarmonies, 0.1, [0.02, 0.035]);

        // 2. Applichiamo l'HPF SOLO al segnale che andrà nel riverbero
        fxSignal = HPF.ar(fxSignal, 400);

        // 3. Generiamo il riverbero 100% wet (mix: 1.0)
        fxSignal = FreeVerb.ar(fxSignal, mix: 1.0, room: 0.7, damp: 0.5);

        // 4. Sommiamo le armonie dry al loro riverbero filtrato (dosando la quantità, ex mix: 0.4)
        sigHarmonies = sigHarmonies + (fxSignal * 0.4);

        // --- FINE MODIFICA ---

        // MIX FINALE
        finalSig = dryVoice + (sigHarmonies * mix);
        finalSig = finalSig * amp * EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);

        // Limiter sul master per proteggere l'intero output audio
        finalSig = Limiter.ar(finalSig, 0.98, 0.01);
        Out.ar(0, finalSig);
    }).add;
    s.sync;

    // --- RICEVITORI OSC (CON LOGICA FREEZE ATTIVA) ---
    OSCdef.freeAll;

    OSCdef(\vocalPitch, { |msg|
        ~vocalPitch = msg[1];

        if(~activeSynth.notNil) {
            if(~isFrozen == 1) {
                // MODO FREEZE: Aggiorna solo la voce per compensare i movimenti, ma non l'accordo!
                ~activeSynth.set(\vocalPitch, ~vocalPitch);
            } {
                // MODO NORMALE
                if(~sourceSelect == 0) {
                    ~rootFreq = msg[1];
                };
                ~activeSynth.set(
                    \vocalPitch, ~vocalPitch,
                    \freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch)
                );
            };
        };
    }, '/vocalPitch');

    OSCdef(\guitarPitch, { |msg|
        if(~sourceSelect == 1) {
            if(~isFrozen == 0) { // La chitarra aggiorna l'accordo SOLO se NON siamo in Freeze
                ~rootFreq = msg[1];
                if(~activeSynth.notNil) {
                    ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
                }
            }
        }
    }, '/guitarPitch');

    OSCdef(\sourceSelect, { |msg| ~sourceSelect = msg[1]; }, '/sourceSelect');

    OSCdef(\freeze, { |msg|
        ~isFrozen = msg[1].asInteger;
        "Stato Freeze: %".format(~isFrozen).postln;
    }, '/freeze');

    // Mappatura sensori separata (ideale per Processing o interfacce Arduino dedicate)
    OSCdef(\complexity, { |msg|
        ~complexity = msg[1].asInteger;
		"Nuova Complessità: %".format(~complexity).postln; // <-- Aggiunto per il debug
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/complexity');

    OSCdef(\mix, { |msg|
        var valMix = msg[1].asFloat;
		"Nuovo Mix: %".format(valMix.round(0.01)).postln; // <-- Aggiunto per il debug
        if(~activeSynth.notNil) {
            ~activeSynth.set(\mix, valMix.lag(0.05));
        }
    }, '/mix');

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
    "SISTEMA DEFINITIVO PRONTO E IN ASCOLTO".postln;
    "=============================".postln;
});
)