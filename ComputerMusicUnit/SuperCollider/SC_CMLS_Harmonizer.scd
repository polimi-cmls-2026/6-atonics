(
s.options.memSize = 65536;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 2;

// Forza l'uso dell'ASIO virtuale di VoiceMeeter
s.options.device = "ASIO : Voicemeeter AUX Virtual ASIO"; // Verificare il nome esatto stampando ServerOptions.devices
s.options.sampleRate = 44100;
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
	~isFrozen = 0;

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
        var dryVoice, harmonies, safeVocalPitch, sigHarmonies, finalSig, smoothFreqs;
        var voiceGates, pitchRatios; // <-- Variabili aggiunte all'inizio

        // Da qui in poi SOLO esecuzione e assegnazioni (nessun 'var')
        dryVoice = SoundIn.ar(vocalIn);

        // 1. SMOOTHING: Applichiamo il Lag ai segnali di controllo in ingresso
        safeVocalPitch = Lag.kr(vocalPitch.max(70), 0.05);
        smoothFreqs = Lag.kr(freqs.max(1), 0.05);

        // Crea un array di gate (0 o 1) basato sulle frequenze originali
        voiceGates = Lag.kr(freqs > 0, 0.05);       // <-- 'var' rimosso
        pitchRatios = smoothFreqs / safeVocalPitch; // <-- 'var' rimosso

        harmonies = pitchRatios.collect({ |ratio, i|
            // Nota: qui 'var' è ammesso perché ci troviamo all'inizio
            // di una NUOVA funzione (la closure passata a .collect)
            var safeRatio = Select.kr(freqs[i] > 0, [1.0, ratio]);

            var shifted = PitchShift.ar(dryVoice, 0.1, safeRatio, 0.0, 0.005);
            shifted = LPF.ar(shifted, 4500);

            // Moltiplica per il gate (che vale 0 se la frequenza in ingresso era 0)
            shifted * voiceGates[i];
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
        // Modifica le ultime righe del SynthDef in questo modo:
		finalSig = dryVoice + (sigHarmonies * mix);
		finalSig = finalSig * amp * EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);

		// Limiter sul master prima dell'uscita
		finalSig = Limiter.ar(finalSig, 0.98, 0.01);
		Out.ar(0, finalSig);
    }).add;
    s.sync; // Attende il completamento della compilazione del Synth

    // --- RICEVITORI OSC AGGIORNATI ---
    OSCdef.freeAll;

    // Pitch da JUCE (VOCE)
    OSCdef(\vocalPitch, { |msg|
        ~vocalPitch = msg[1];

        if(~activeSynth.notNil) {
            if(~isFrozen == 1) {
                // MODO FREEZE: Non ricalcoliamo le frequenze dell'accordo.
                // TUTTAVIA, continuiamo a inviare il vocalPitch al Synth!
                // Questo permette al SynthDef di aggiornare i `pitchRatios` in tempo reale.
                // Anche se il cantante si muove, le armonie in uscita resteranno perfettamente congelate.
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

    // Pitch da JUCE (CHITARRA)
    OSCdef(\guitarPitch, { |msg|
        if(~sourceSelect == 1) {
            // MODO NORMALE: La chitarra detta l'armonia SOLO se NON siamo in Freeze
            if(~isFrozen == 0) {
                ~rootFreq = msg[1];
                if(~activeSynth.notNil) {
                    ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
                }
            }
        }
    }, '/guitarPitch');

    // Sensori da Processing: Freeze (0 o 1)
    OSCdef(\freeze, { |msg|
        ~isFrozen = msg[1].asInteger;
        "Stato Freeze: %".format(~isFrozen).postln;
    }, '/freeze');

    OSCdef(\sourceSelect, { |msg| ~sourceSelect = msg[1]; }, '/sourceSelect');

    // Sensori da Processing: Complessità (1-4)
    OSCdef(\complexity, { |msg|
        ~complexity = msg[1].asInteger;
        "Nuova Complessità: %".format(~complexity).postln; // <-- Aggiunto per il debug
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/complexity');

    // Sensori da Processing: Mix (0.0 - 1.0)
    OSCdef(\mix, { |msg|
        var valMix = msg[1].asFloat;
        "Nuovo Mix: %".format(valMix.round(0.01)).postln; // <-- Aggiunto per il debug
        if(~activeSynth.notNil) {
            ~activeSynth.set(\mix, valMix.lag(0.05));
        }
    }, '/mix');

    // GUI: Imposta la nota fondamentale (Int MIDI)
    OSCdef(\tonic, { |msg|
        ~tonicMidi = msg[1].asInteger;
        "Nuova Tonica: %".format(~tonicMidi).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/tonic');

    // GUI: Imposta il modo (0 = Magg, 1 = Min)
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

OSCFunc.trace(true);
OSCFunc.trace(false);