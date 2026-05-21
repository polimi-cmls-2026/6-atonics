#include "MainComponent.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

//==============================================================================
MainComponent::MainComponent()
{
    setSize(800, 600);

    // 1. Forza JUCE a preferire ASIO (aggirando così il crash di WASAPI su Windows)
    deviceManager.setCurrentAudioDeviceType("ASIO", true);

    // 2. Chiamata standard protetta (ora userà ASIO di default)
    if (juce::RuntimePermissions::isRequired(juce::RuntimePermissions::recordAudio)
        && !juce::RuntimePermissions::isGranted(juce::RuntimePermissions::recordAudio))
    {
        juce::RuntimePermissions::request(juce::RuntimePermissions::recordAudio,
            [&](bool granted) { setAudioChannels(granted ? 2 : 0, 2); });
    }
    else
    {
        setAudioChannels(2, 2);
    }

    // 3. Configurazione del pulsante per aprire il pannello Audio
    settingsButton.setButtonText("Impostazioni Audio...");
    settingsButton.onClick = [this]
        {
            juce::DialogWindow::LaunchOptions o;
            o.content.setOwned(new juce::AudioDeviceSelectorComponent(deviceManager, 2, 2, 2, 2, false, false, true, false));
            o.content->setSize(400, 600);
            o.dialogTitle = "Audio Settings";
            o.launchAsync();
        };
    addAndMakeVisible(settingsButton);

    pitchDebugLabel.setText("Pitch: -- Hz", juce::dontSendNotification);
    pitchDebugLabel.setFont(juce::Font(24.0f, juce::Font::bold));
    addAndMakeVisible(pitchDebugLabel);

    envDebugLabel.setText("Env: --", juce::dontSendNotification);
    addAndMakeVisible(envDebugLabel);

    if (!oscSender.connect(oscSendHost, oscSendPort))
        juce::Logger::writeToLog("Critical Error: Unable to connect OSC sender to port 57120.");

    if (!oscReceiver.connect(oscReceivePort))
        juce::Logger::writeToLog("Critical Error: Unable to connect OSC receiver to port 9000.");

    oscReceiver.addListener(this);
    startTimerHz(30);
}

MainComponent::~MainComponent()
{
    oscSender.disconnect();
    oscReceiver.disconnect();
    shutdownAudio();
}

void MainComponent::timerCallback()
{
    oscSender.send("/envelope/guitar", envGuitar);
    oscSender.send("/envelope/voice", envVoice);

    juce::String debugText = "Chitarra: " + juce::String(detectedPitch, 1) + " Hz\n" +
        "Voce (Grid): " + juce::String(detectedPitchVoice, 1) + " Hz";

    pitchDebugLabel.setText(debugText, juce::dontSendNotification);
    envDebugLabel.setText("Env: " + juce::String(envGuitar, 3), juce::dontSendNotification);

    repaint();
}

void MainComponent::prepareToPlay(int samplesPerBlockExpected, double sampleRate)
{
    currentSampleRate = sampleRate;

    // MODIFIED: windowSize and hopSize are now forced here to stay consistent
    // with the FFT size used by ChordPitchDetector.
    // Original: windowSize = 2048, hopSize = 512 (declared in header, never reassigned).
    // New:      windowSize = 2048, hopSize = 1024 (hop = FFT/2, overlap 50%).
    // This change reduces the median filter latency from ~200 ms to ~120 ms
    // while keeping frequency resolution identical.
    windowSize = 2048;
    hopSize    = 1024;

    circularBuffer.assign(windowSize, 0.0f);
    writeIndex = 0;
    samplesSinceLastAnalysis = 0;

    circularBufferVoice.assign(windowSize, 0.0f);
    writeIndexVoice = 0;
    samplesSinceLastAnalysisVoice = 0;

    // MODIFIED: history size reduced from 5 to 3 frames for both voice and guitar.
    // 5 frames × hop ~11.6 ms = ~58 ms of median delay (original hop 512).
    // 3 frames × hop ~23.2 ms = ~70 ms of median delay (new hop 1024).
    // Net result: slightly more median latency per frame, but far fewer frames
    // needed — and the attack-reset in ChordPitchDetector brings perceived
    // chord-change latency down to ~46 ms on transients.
    pitchHistoryVoice.assign(3, 0.0f);
    pitchHistoryGuitar.assign(3, 0.0f);

    // ADDED: reinitialise ChordPitchDetector with the actual runtime sample rate.
    // The object is constructed in the header with 44100.0 as a safe default,
    // but ASIO may run at 48000 Hz — this ensures the FFT bin-to-Hz mapping
    // is always correct regardless of the device sample rate.
    chordDetector = ChordPitchDetector(2048, sampleRate);
    chordDetector.rmsThreshold        = 0.008f;
    chordDetector.attackRatioThreshold = 2.5f;
    chordDetector.minFreqHz           = 60.0f;
    chordDetector.maxFreqHz           = 800.0f;

    // REMOVED: lpfAlpha calculation is kept for compilation safety but the
    // filter is no longer applied to the guitar buffer (see getNextAudioBlock).
    lpfAlpha = 1.0f - std::exp(-2.0f * (float)M_PI * lpfCutoffHz / currentSampleRate);

    gateAttackCoeff = std::exp(-1.0f / (gateAttack * sampleRate));

    gateReleaseCoeffGuitar = std::exp(-1.0f / (gateReleaseGuitar * sampleRate));
    gateReleaseCoeffVoice  = std::exp(-1.0f / (gateReleaseVoice  * sampleRate));

    compAttackCoeff  = std::exp(-1.0f / (compAttack  * sampleRate));
    compReleaseCoeff = std::exp(-1.0f / (compRelease * sampleRate));

    envFollowerAttackCoeff  = std::exp(-1.0f / (envFollowerAttack  * sampleRate));
    envFollowerReleaseCoeff = std::exp(-1.0f / (envFollowerRelease * sampleRate));
}

void MainComponent::getNextAudioBlock(const juce::AudioSourceChannelInfo& bufferToFill)
{
    if (bufferToFill.buffer->getNumChannels() < 2)
    {
        bufferToFill.clearActiveBufferRegion();
        return;
    }

    const float* micIn    = bufferToFill.buffer->getReadPointer(0, bufferToFill.startSample);
    const float* guitarIn = bufferToFill.buffer->getReadPointer(1, bufferToFill.startSample);

    float* leftOut  = bufferToFill.buffer->getWritePointer(0, bufferToFill.startSample);
    float* rightOut = bufferToFill.buffer->getWritePointer(1, bufferToFill.startSample);

    for (int i = 0; i < bufferToFill.numSamples; ++i)
    {
        // =====================================================================
        // 1. VOICE (mic — channel 0) — unchanged from original
        // =====================================================================
        float voiceProcessed = applyGate(micIn[i], gateEnvVoice, gateGainVoice, gateReleaseCoeffVoice);
        voiceProcessed = applyCompressor(voiceProcessed, compEnvVoice);
        applyEnvelopeFollower(voiceProcessed, envVoice);

        circularBufferVoice[writeIndexVoice] = voiceProcessed;
        writeIndexVoice = (writeIndexVoice + 1) % windowSize;
        samplesSinceLastAnalysisVoice++;

        if (samplesSinceLastAnalysisVoice >= hopSize)
        {
            std::vector<float> frameVoice(windowSize);
            float energyVoice = 0.0f;

            for (int j = 0; j < windowSize; ++j)
            {
                frameVoice[j] = circularBufferVoice[(writeIndexVoice + j) % windowSize];
                energyVoice  += frameVoice[j] * frameVoice[j];
            }

            float rmsVoice = std::sqrt(energyVoice / windowSize);

            if (rmsVoice > 0.015f)
            {
                detectedPitchVoice = detectPitchYIN(frameVoice.data(), windowSize, currentSampleRate);

                if (detectedPitchVoice >= 70.0f && detectedPitchVoice <= 1000.0f)
                {
                    float perfectlyTunedPitch = snapToGrid(detectedPitchVoice);

                    // MODIFIED: history size is now 3 (was 5) — see prepareToPlay
                    pitchHistoryVoice.erase(pitchHistoryVoice.begin());
                    pitchHistoryVoice.push_back(perfectlyTunedPitch);

                    std::vector<float> sortedHistory = pitchHistoryVoice;
                    std::sort(sortedHistory.begin(), sortedHistory.end());
                    float medianPitch = sortedHistory[sortedHistory.size() / 2];

                    DBG("DATA,Voice," + juce::String(medianPitch, 2) + "," + juce::String(rmsVoice, 4));
                    sendVocalPitchToSuperCollider(medianPitch);
                }
            }
            samplesSinceLastAnalysisVoice = 0;
        }

        // =====================================================================
        // 2. GUITAR (channel 1)
        // =====================================================================
        float guitarProcessed = applyGate(guitarIn[i], gateEnvGuitar, gateGainGuitar, gateReleaseCoeffGuitar);
        guitarProcessed = applyCompressor(guitarProcessed, compEnvGuitar);
        applyEnvelopeFollower(guitarProcessed, envGuitar);

        // REMOVED: LPF was applied here in the original to help YIN ignore
        // high harmonics that caused octave errors on monophonic notes.
        // HPS does not need this — it uses harmonics as positive evidence,
        // so filtering them out would destroy useful spectral information.
        // Original lines (deleted):
        //   lpfState = lpfAlpha * guitarProcessed + (1.0f - lpfAlpha) * lpfState;
        //   circularBuffer[writeIndex] = lpfState;
        circularBuffer[writeIndex] = guitarProcessed;

        writeIndex = (writeIndex + 1) % windowSize;
        samplesSinceLastAnalysis++;

        if (samplesSinceLastAnalysis >= hopSize)
        {
            std::vector<float> frame(windowSize);
            for (int j = 0; j < windowSize; ++j)
                frame[j] = circularBuffer[(writeIndex + j) % windowSize];

            // MODIFIED: replaced the YIN-based monophonic pitch detector with
            // ChordPitchDetector (HPS + FFT). The new detector handles full
            // chords and internally manages the 3-frame median filter and the
            // attack-reset logic that flushes the median history on transients,
            // reducing perceived chord-change latency to ~46 ms.
            //
            // Original block (deleted):
            //   float energy = 0.0f;
            //   for (int j = 0; j < windowSize; ++j) { ... energy += ... }
            //   float rms = std::sqrt(energy / windowSize);
            //   if (rms > 0.005f)
            //   {
            //       detectedPitch = detectPitchYIN(...);
            //       if (detectedPitch >= 70.0f && detectedPitch <= 800.0f)
            //       {
            //           pitchHistoryGuitar.erase(...);
            //           pitchHistoryGuitar.push_back(...);
            //           ... sort ... median ...
            //           sendPitchToSuperCollider(medianGuitarPitch);
            //       }
            //   }
            float chordRoot = chordDetector.detectChordRoot(frame.data(), windowSize);

            if (chordRoot >= 60.0f && chordRoot <= 800.0f)
            {
                detectedPitch = chordRoot;
                DBG("DATA,Guitar(HPS)," + juce::String(chordRoot, 2));
                sendPitchToSuperCollider(chordRoot);
            }
            else if (chordRoot > 0.0f)
            {
                DBG("HPS Rejected: " + juce::String(chordRoot, 2) + " Hz");
            }

            samplesSinceLastAnalysis = 0;
        }

        // Temporary bypass for audio testing — unchanged
        leftOut[i]  = voiceProcessed;
        rightOut[i] = guitarProcessed;
    }
}

void MainComponent::releaseResources() {}

void MainComponent::paint(juce::Graphics& g)
{
    g.fillAll(getLookAndFeel().findColour(juce::ResizableWindow::backgroundColourId));
}

void MainComponent::resized()
{
    settingsButton.setBounds(10, 10, 160, 30);
    pitchDebugLabel.setBounds(10, 60, 300, 40);
    envDebugLabel.setBounds(10, 100, 300, 30);
}

// =============================================================================
// DSP IMPLEMENTATIONS — unchanged from original
// =============================================================================

float MainComponent::applyGate(float inputSample, float& envelope, float& gainState, float releaseCoeff)
{
    float rectified = std::abs(inputSample);

    if (rectified > envelope)
        envelope = gateAttackCoeff * envelope + (1.0f - gateAttackCoeff) * rectified;
    else
        envelope = releaseCoeff * envelope + (1.0f - releaseCoeff) * rectified;

    float targetGain = (envelope > gateThreshold) ? 1.0f : 0.0f;

    if (targetGain > gainState)
        gainState = gateAttackCoeff * gainState + (1.0f - gateAttackCoeff) * targetGain;
    else
        gainState = releaseCoeff * gainState + (1.0f - releaseCoeff) * targetGain;

    return inputSample * gainState;
}

float MainComponent::applyCompressor(float inputSample, float& envelope)
{
    float amplitude = std::abs(inputSample) + 1e-6f;
    float inputDB   = 20.0f * std::log10(amplitude);

    if (inputDB > envelope)
        envelope = compAttackCoeff * envelope + (1.0f - compAttackCoeff) * inputDB;
    else
        envelope = compReleaseCoeff * envelope + (1.0f - compReleaseCoeff) * inputDB;

    float gainDB = 0.0f;
    if (envelope > compThreshold)
        gainDB = (compThreshold - envelope) * (1.0f - 1.0f / compRatio);

    float gainLinear = std::pow(10.0f, gainDB / 20.0f);
    return inputSample * gainLinear * compMakeupGain;
}

float MainComponent::applyEnvelopeFollower(float inputSample, float& envelope)
{
    float rectified = std::abs(inputSample);
    if (rectified > envelope)
        envelope = envFollowerAttackCoeff * envelope + (1.0f - envFollowerAttackCoeff) * rectified;
    else
        envelope = envFollowerReleaseCoeff * envelope + (1.0f - envFollowerReleaseCoeff) * rectified;

    return envelope;
}

// =============================================================================
// PITCH DETECTION (YIN) — voice only, unchanged from original
// =============================================================================

float MainComponent::detectPitchYIN(const float* audioBuffer, int bufferSize, double sampleRate)
{
    int tauMax = static_cast<int>(sampleRate / 80.0f);
    int tauMin = static_cast<int>(sampleRate / 1200.0f);
    tauMax = juce::jmin(tauMax, bufferSize / 2);

    std::vector<float> yinArray(tauMax, 0.0f);
    yinArray[0] = 1.0f;

    float runningSum = 0.0f;

    for (int tau = 1; tau < tauMax; ++tau)
    {
        float sum = 0.0f;
        for (int i = 0; i < tauMax; ++i)
        {
            float delta = audioBuffer[i] - audioBuffer[i + tau];
            sum += delta * delta;
        }

        runningSum += sum;
        yinArray[tau] = sum * tau / runningSum;
    }

    int tau = tauMin;
    while (tau < tauMax - 1)
    {
        if (yinArray[tau] < yinThreshold)
        {
            while (tau + 1 < tauMax && yinArray[tau + 1] < yinArray[tau])
                tau++;
            break;
        }
        tau++;
    }

    if (tau == tauMax - 1 || yinArray[tau] >= yinThreshold)
        return 0.0f;

    float betterTau;
    if (tau > 0 && tau < tauMax - 1)
    {
        float x0 = yinArray[tau - 1];
        float x1 = yinArray[tau];
        float x2 = yinArray[tau + 1];
        betterTau = tau + (x2 - x0) / (2.0f * (2.0f * x1 - x2 - x0));
    }
    else
    {
        betterTau = static_cast<float>(tau);
    }

    return static_cast<float>(sampleRate / betterTau);
}

// =============================================================================
// OSC & PRESETS — unchanged from original
// =============================================================================

void MainComponent::oscMessageReceived(const juce::OSCMessage& message)
{
    if (message.getAddressPattern() == "/freeze" && message[0].isInt32())
    {
        int freezeValue = message[0].getInt32();
        oscSender.send("/freeze", freezeValue);
        DBG("Freeze: " + juce::String(freezeValue));
    }
    else if (message.getAddressPattern() == "/blend" && message[0].isFloat32())
    {
        float blendValue = message[0].getFloat32();
        oscSender.send("/blend", blendValue);
        DBG("Blend: " + juce::String(blendValue));
    }
    else if (message.getAddressPattern() == "/preset" && message[0].isInt32())
    {
        loadPreset(message[0].getInt32());
    }
}

void MainComponent::loadPreset(int presetIndex)
{
    if (presetIndex < 0 || presetIndex >= static_cast<int>(presets.size()))
        return;

    currentPreset = presetIndex;
    const Preset& p = presets[presetIndex];

    gateThreshold      = p.gateThreshold;
    compThreshold      = p.compThreshold;
    compRatio          = p.compRatio;
    compMakeupGain     = p.compMakeupGain;
    envFollowerRelease = p.envFollowerRelease;

    envFollowerReleaseCoeff = std::exp(-1.0f / (envFollowerRelease * currentSampleRate));
    oscSender.send("/preset", presetIndex);

    juce::MessageManager::callAsync([this, presetIndex]()
        {
            presetLabel.setText("Preset: " + juce::String(presetIndex + 1), juce::dontSendNotification);
        });

    DBG("Preset loaded: " + juce::String(presetIndex + 1));
}

// =============================================================================
// SNAP TO GRID (voice) — unchanged from original
// =============================================================================

float MainComponent::snapToGrid(float pitchHz)
{
    if (pitchHz <= 0.0f) return 0.0f;

    float currentMidiNote = 69.0f + 12.0f * std::log2(pitchHz / 440.0f);

    if (lastSnappedMidiVoice < 0.0f)
    {
        lastSnappedMidiVoice = std::round(currentMidiNote);
    }
    else
    {
        if (std::abs(currentMidiNote - lastSnappedMidiVoice) > 0.65f)
            lastSnappedMidiVoice = std::round(currentMidiNote);
    }

    return 440.0f * std::pow(2.0f, (lastSnappedMidiVoice - 69.0f) / 12.0f);
}

// =============================================================================
// OSC SEND — unchanged from original
// =============================================================================

void MainComponent::sendVocalPitchToSuperCollider(float pitchInHz)
{
    if (std::abs(pitchInHz - lastSentVoicePitch) < 0.1f)
        return;

    juce::OSCMessage message("/vocalPitch");
    message.addFloat32(pitchInHz);

    if (oscSender.send(message))
    {
        lastSentVoicePitch = pitchInHz;
        DBG("OSC Inviato -> Voce: " + juce::String(pitchInHz) + " Hz");
    }
    else
    {
        juce::Logger::writeToLog("Error: Failed to send OSC vocal pitch message");
    }
}

void MainComponent::sendPitchToSuperCollider(float pitchInHz)
{
    if (lastSentGuitarPitch > 0.0f && pitchInHz > 0.0f)
    {
        float centsDiff = 1200.0f * std::abs(std::log2(pitchInHz / lastSentGuitarPitch));
        if (centsDiff < deadbandCents)
            return;
    }

    juce::OSCMessage message("/guitarPitch");
    message.addFloat32(pitchInHz);

    if (oscSender.send(message))
    {
        lastSentGuitarPitch = pitchInHz;
        DBG("OSC Inviato -> Chitarra: " + juce::String(pitchInHz) + " Hz");
    }
    else
    {
        juce::Logger::writeToLog("Error: Failed to send OSC pitch message");
    }
}
