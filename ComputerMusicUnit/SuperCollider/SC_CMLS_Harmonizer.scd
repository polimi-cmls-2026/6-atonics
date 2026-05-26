(
s.options.memSize = 65536;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 2;

// Force VoiceMeeter Virtual ASIO (make sure the name matches your system)
s.options.device = "ASIO : Voicemeeter AUX Virtual ASIO";
s.options.sampleRate = 44100;
s.boot;

s.waitForBoot({
    "Init Diatonic Logic and DSP (Definitive Edition)...".postln;

    // --- STATE VARIABLES ---
    ~rootFreq = 440;
    ~vocalPitch = 440;
    ~complexity = 2;         // Default: Triad
    ~tonicMidi = 69;         // 60 = C
    ~scaleMode = 0;          // 0 = Major, 1 = Natural Minor
    ~sourceSelect = 1;       // 1 = Guitar-based, 0 = Voice-based
    ~gain = 0.5;
    ~isFrozen = 0;           // Pedal bypassed by default

    // --- HARMONIC DATA STRUCTURES ---
    ~getScale = { arg mode = 0;
        if(mode.asInteger == 1, { [0, 2, 3, 5, 7, 8, 10] }, { [0, 2, 4, 5, 7, 9, 11] })
    };

    ~getNearestScaleNote = { arg midiNote, tonic, mode, forceUp = false;
        var scale = ~getScale.value(mode);
        var inputMidi = midiNote.round.asInteger;
        var baseOctave = ((inputMidi - tonic) / 12).floor.asInteger;
        var bestDist = 1000, nearestMidi = inputMidi, nearestDegree = 0, nearestOctave = baseOctave;

        if(forceUp, {
            // VOICE LOGIC: Find the first diatonic note >= the sung note (Shift Up)
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
            // GUITAR LOGIC: Find the note with the smallest absolute distance
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

    // --- CHORD CALCULATION ---
    ~getChordFreqs = { arg root, complexity, tonic, mode, vocalPitch;
        var rootMidi = root.max(20).cpsmidi.round.asInteger;
        var isVoiceDriving = (~sourceSelect == 0);

        var noteInfo = ~getNearestScaleNote.value(rootMidi, tonic, mode, isVoiceDriving);
        var rMidi = noteInfo[0], rDegree = noteInfo[1], rOctave = noteInfo[2];

        var vocalMidi = vocalPitch.max(20).cpsmidi;
        var chordMidi;

        var degreeSteps = switch(complexity.asInteger.clip(1, 4),
            1, { [0, 4] },             // Power Chord
            2, { [0, 2, 4] },          // Triad
            3, { [0, 2, 4, 6] },       // 7th Chord
            4, { [0, 2, 4, 6, 8] }     // 9th Chord
        );

        // Generate diatonic degrees using Jazz rules (b9 Avoid Notes) and Minor Dominant
        chordMidi = degreeSteps.collect({ arg step;
            var noteMidi;
            var actualStep = step;

            // 9th handling
            if(step == 8, {
                if(mode.asInteger == 0, { // MAJOR
                    if(rDegree == 2, { actualStep = 10; });
                    if(rDegree == 6, { actualStep = 12; });
                }, { // MINOR
                    if(rDegree == 1, { actualStep = 12; });
                    if(rDegree == 4, { actualStep = 12; });
                });
            });

            noteMidi = ~getDiatonicMidiNote.value(tonic, mode, rDegree + actualStep, rOctave);

            // Leading tone in minor on the 5th degree
            if((mode.asInteger == 1) && (rDegree == 4) && (actualStep == 2), {
                noteMidi = noteMidi + 1;
            });

            noteMidi;
        });

        // Vocal Anchoring
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

    // --- SYNTHDEF: HYBRID PITCH-SHIFT + FORMANT PRESERVATION ---
    SynthDef(\trueHarmonizer, {
        arg vocalPitch = 440, freqs = #[440, 554, 659, 0, 0, 0], amp = 0.5, gate = 1, vocalIn = 0, mix = 1.0;

        var dryVoice, safeVocalPitch, smoothFreqs, voiceGates, pitchRatios;
        var shiftedSource, harmonies, fxSignal, sigHarmonies, finalSig, breath;
        var numBands = 48, bandFreqs, formants;

        dryVoice = SoundIn.ar(vocalIn);

        // Control signal smoothing
        safeVocalPitch = Lag.kr(vocalPitch.max(70), 0.05);
        smoothFreqs = Lag.kr(freqs.max(1), 0.05);
        voiceGates = Lag.kr(freqs > 0, 0.05);
        pitchRatios = smoothFreqs / safeVocalPitch;

        // 1. ANALYSIS: Formant Envelope Extraction (Voice footprint)
        bandFreqs = (1..numBands).collect({ |i| i.linexp(1, numBands, 80, 12000) });
        formants = bandFreqs.collect({ |f|
            Amplitude.ar(BPF.ar(dryVoice, f, 0.15), 0.005, 0.05);
        });

        // 2. HYBRID SOURCE WITH HUMANIZATION & ANTI-GLITCH
        shiftedSource = pitchRatios.collect({ |ratio, i|
            var safeRatio = Select.kr(freqs[i] > 0, [1.0, ratio]);
            var noteChangeTrig, duckMask, drift, humanRatio, shift, microDelay;

            // --- Anti-Glitch (Slew-Rate Masking) ---
            // Intercept note changes. Env.perc ducks the volume to 0 for a few ms
            // to mask the granular buffer recalculation.
            noteChangeTrig = Changed.kr(freqs[i]);
            duckMask = 1.0 - EnvGen.kr(Env.perc(0.005, 0.05, 1.0, -4), noteChangeTrig);

            // --- Pitch Drift (Organic Vibrato) ---
            // Smooth, asynchronous oscillation for each voice (0.2 to 0.6 Hz).
            drift = LFNoise2.kr(Rand(0.2, 0.6)).range(-0.015, 0.015);
            humanRatio = safeRatio + (drift * (freqs[i] > 0)); // Apply only if note is active

            // Granular engine
            shift = PitchShift.ar(dryVoice, 0.1, humanRatio, 0.0, 0.005);

            // --- Micro-Timing ---
            // Independent delay (5-35ms) to spread the attacks.
            microDelay = DelayC.ar(shift, 0.05, Rand(0.005, 0.035));

            // Sum with gates and anti-glitch mask
            microDelay * voiceGates[i] * duckMask;
        }).sum;

        // 3. SYNTHESIS & GAIN STAGING
        harmonies = bandFreqs.collect({ |f, i|
            BPF.ar(shiftedSource, f, 0.15) * formants[i];
        }).sum;

        harmonies = HPF.ar(harmonies, 80);

        // High shelf boost (+6dB) above 6000 Hz to open up the top end
        harmonies = BHiShelf.ar(harmonies, 6000, 1.0, 6.0);

        // Softer saturation to avoid crushing high frequencies
        harmonies = (harmonies * 8.0).tanh * 2.0;

        // Intelligibility recovery: grab "S" and "T" transients from the clean voice
        // and add them back to the choir (only when chords are active).
        breath = HPF.ar(dryVoice, 6000) * (freqs > 0).sum.sign * 0.20;
        harmonies = harmonies + breath;

        // 4. FX & SPATIALIZATION
        fxSignal = DelayN.ar(harmonies, 0.1, [0.02, 0.035]);
        fxSignal = HPF.ar(fxSignal, 400);
        fxSignal = FreeVerb.ar(fxSignal, mix: 1.0, room: 0.7, damp: 0.5);

        sigHarmonies = DelayN.ar(harmonies, 0.1, [0.02, 0.035]) * 1.2 + (fxSignal * 0.4);

        // FINAL MIX
        finalSig = dryVoice + (sigHarmonies * mix);
        finalSig = finalSig * amp * EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);

        finalSig = Limiter.ar(finalSig, 0.98, 0.01);
        Out.ar(0, finalSig);
    }).add;

    s.sync;

    // --- OSC RECEIVERS (WITH FREEZE LOGIC) ---
    OSCdef.freeAll;

    OSCdef(\vocalPitch, { |msg|
        ~vocalPitch = msg[1];

        "[VOICE] %".format(~vocalPitch.round(0.01)).postln;

        if(~activeSynth.notNil) {
            if(~isFrozen == 1) {
                // FREEZE MODE: Update vocal pitch to compensate for drift, but keep the chord locked!
                ~activeSynth.set(\vocalPitch, ~vocalPitch);
            } {
                // NORMAL MODE
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
            if(~isFrozen == 0) { // Guitar updates the chord ONLY if Freeze is bypassed
                ~rootFreq = msg[1];

                "[GUITAR] %".format(~rootFreq.round(0.01)).postln;

                if(~activeSynth.notNil) {
                    ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
                }
            }
        }
    }, '/guitarPitch');

    OSCdef(\sourceSelect, { |msg| ~sourceSelect = msg[1]; }, '/sourceSelect');

    OSCdef(\freeze, { |msg|
        ~isFrozen = msg[1].asInteger;
        "Freeze State: %".format(~isFrozen).postln;
    }, '/freeze');

    // Discrete sensor mapping (ideal for Processing or Arduino interfaces)
    OSCdef(\complexity, { |msg|
        ~complexity = msg[1].asInteger;
        "New Complexity: %".format(~complexity).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/complexity');

    OSCdef(\mix, { |msg|
        var valMix = msg[1].asFloat;
        "New Mix: %".format(valMix.round(0.01)).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\mix, valMix.lag(0.05));
        }
    }, '/mix');

    OSCdef(\tonic, { |msg|
        ~tonicMidi = msg[1].asInteger;
        "New Tonic: %".format(~tonicMidi).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/tonic');

    OSCdef(\mode, { |msg|
        ~scaleMode = msg[1].asInteger;
        "New Mode: %".format(~scaleMode).postln;
        if(~activeSynth.notNil) {
            ~activeSynth.set(\freqs, ~getChordFreqs.value(~rootFreq, ~complexity, ~tonicMidi, ~scaleMode, ~vocalPitch));
        }
    }, '/mode');

    // --- SYSTEM START ---
    if(~activeSynth.notNil) { ~activeSynth.free };

    ~activeSynth = Synth(\trueHarmonizer, [\freqs, ~getChordFreqs.value(440, ~complexity, ~tonicMidi, ~scaleMode, 440), \amp, 0.5]);

    "=============================".postln;
    "DEFINITIVE SYSTEM READY AND LISTENING".postln;
    "=============================".postln;
});
)
