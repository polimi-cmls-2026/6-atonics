#include "MainComponent.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

//==============================================================================
MainComponent::MainComponent()
{
    setSize(800, 600);

    // Force ASIO drivers
    deviceManager.setCurrentAudioDeviceType("ASIO", true);

    // 2. Protected standard call (ASIO)
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

    // 3. Button to open audio settings
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
    // 1. Lettura thread-safe dei valori calcolati dal DSP
    float currentVoice = uiPitchVoice.load(std::memory_order_relaxed);
    float currentGuitar = uiPitchGuitar.load(std::memory_order_relaxed);

    // 2. Invio Inviluppi (già lo facevi)
    oscSender.send("/envelope/guitar", envGuitar);
    oscSender.send("/envelope/voice", envVoice);

    // 3. Logica di invio OSC Voce (Spostata qui dal thread audio)
    if (currentVoice > 0.0f && std::abs(currentVoice - lastSentVoicePitch) >= 0.1f)
    {
        juce::OSCMessage msgVoice("/vocalPitch");
        msgVoice.addFloat32(currentVoice);
        if (oscSender.send(msgVoice)) {
            lastSentVoicePitch = currentVoice;
        }
    }

    // 4. Logica di invio OSC Chitarra (Spostata qui, con deadband in cents)
    if (lastSentGuitarPitch > 0.0f && currentGuitar > 0.0f)
    {
        float centsDiff = 1200.0f * std::abs(std::log2(currentGuitar / lastSentGuitarPitch));
        if (centsDiff >= deadbandCents)
        {
            juce::OSCMessage msgGuitar("/guitarPitch");
            msgGuitar.addFloat32(currentGuitar);
            if (oscSender.send(msgGuitar)) {
                lastSentGuitarPitch = currentGuitar;
            }
        }
    }
    else if (currentGuitar > 0.0f && lastSentGuitarPitch <= 0.0f) {
        // Primo invio in assoluto
        juce::OSCMessage msgGuitar("/guitarPitch");
        msgGuitar.addFloat32(currentGuitar);
        if (oscSender.send(msgGuitar)) {
            lastSentGuitarPitch = currentGuitar;
        }
    }

    // 5. Aggiornamento UI
    juce::String debugText = "Chitarra: " + juce::String(currentGuitar, 1) + " Hz\n" +
        "Voce: " + juce::String(currentVoice, 1) + " Hz";

    pitchDebugLabel.setText(debugText, juce::dontSendNotification);
    envDebugLabel.setText("Env: " + juce::String(envGuitar, 3), juce::dontSendNotification);

    repaint();
}

void MainComponent::prepareToPlay(int samplesPerBlockExpected, double sampleRate)
{
    currentSampleRate = sampleRate;
    circularBuffer.assign(windowSize, 0.0f);
    writeIndex = 0;
    samplesSinceLastAnalysis = 0;

    chordDetector = ChordPitchDetector(2048, 8192, sampleRate);

    chordDetector.rmsThreshold = 0.005f;
    chordDetector.minFreqHz = 80.0f;

	// Initialize voice processing buffers
    circularBufferVoice.assign(windowSize, 0.0f);
    writeIndexVoice = 0;
    samplesSinceLastAnalysisVoice = 0;

	// Initialize pitch history for median filtering (5 zeros)
    pitchHistoryVoice.assign(5, 0.0f);
    pitchHistoryGuitar.assign(5, 0.0f);

    smoothedMidiVoice = -1.0f;

    // Support vectors pre-allocation
    frameVoice.assign(windowSize, 0.0f);
    sortedHistoryVoice.assign(5, 0.0f);

    frameGuitar.assign(windowSize, 0.0f);
    sortedHistoryGuitar.assign(5, 0.0f);

    lpfAlpha = 1.0f - std::exp(-2.0f * M_PI * lpfCutoffHz / currentSampleRate);

    // Pre-calculate DSP coefficients
    gateAttackCoeff = std::exp(-1.0f / (gateAttack * sampleRate));

	// Separated coefficients for guitar and voice release
    gateReleaseCoeffGuitar = std::exp(-1.0f / (gateReleaseGuitar * sampleRate));
    gateReleaseCoeffVoice = std::exp(-1.0f / (gateReleaseVoice * sampleRate));

    compAttackCoeff = std::exp(-1.0f / (compAttack * sampleRate));
    compReleaseCoeff = std::exp(-1.0f / (compRelease * sampleRate));

    envFollowerAttackCoeff = std::exp(-1.0f / (envFollowerAttack * sampleRate));
    envFollowerReleaseCoeff = std::exp(-1.0f / (envFollowerRelease * sampleRate));
}

void MainComponent::getNextAudioBlock(const juce::AudioSourceChannelInfo& bufferToFill)
{
    if (bufferToFill.buffer->getNumChannels() < 2)
    {
        bufferToFill.clearActiveBufferRegion();
        return;
    }

    const float* micIn = bufferToFill.buffer->getReadPointer(0, bufferToFill.startSample);
    const float* guitarIn = bufferToFill.buffer->getReadPointer(1, bufferToFill.startSample);

    float* leftOut = bufferToFill.buffer->getWritePointer(0, bufferToFill.startSample);
    float* rightOut = bufferToFill.buffer->getWritePointer(1, bufferToFill.startSample);

    for (int i = 0; i < bufferToFill.numSamples; ++i)
    {
        // 1. Process Voice (Mic)
        float voiceProcessed = applyGate(micIn[i], gateEnvVoice, gateGainVoice, gateReleaseCoeffVoice);
        voiceProcessed = applyCompressor(voiceProcessed, compEnvVoice);
        applyEnvelopeFollower(voiceProcessed, envVoice);

		// Circular buffer writing for voice
        circularBufferVoice[writeIndexVoice] = voiceProcessed;
        writeIndexVoice = (writeIndexVoice + 1) % windowSize;
        samplesSinceLastAnalysisVoice++;

        // YIN vocal analysis
        if (samplesSinceLastAnalysisVoice >= hopSize)
        {
            float energyVoice = 0.0f;
            for (int j = 0; j < windowSize; ++j)
            {
                frameVoice[j] = circularBufferVoice[(writeIndexVoice + j) % windowSize];
                energyVoice += frameVoice[j] * frameVoice[j];
            }

            float rmsVoice = std::sqrt(energyVoice / windowSize);

            if (rmsVoice > 0.015f)
            {
                detectedPitchVoice = detectPitchYIN(frameVoice.data(), windowSize, currentSampleRate);

                // Focus on vocal range
                if (detectedPitchVoice >= 70.0f && detectedPitchVoice <= 1000.0f)
                {
                    pitchHistoryVoice.erase(pitchHistoryVoice.begin());
                    pitchHistoryVoice.push_back(detectedPitchVoice);

                    std::copy(pitchHistoryVoice.begin(), pitchHistoryVoice.end(), sortedHistoryVoice.begin());
                    std::sort(sortedHistoryVoice.begin(), sortedHistoryVoice.end());

                    float medianPitchHz = sortedHistoryVoice[sortedHistoryVoice.size() / 2];
                    float currentMidi = 69.0f + 12.0f * std::log2(medianPitchHz / 440.0f);

                    // Riduciamo leggermente l'alpha (es. da 0.25 a 0.4) per renderlo più reattivo
                    float alpha = 0.4f;

                    if (smoothedMidiVoice < 0.0f) {
                        smoothedMidiVoice = currentMidi; // Snap immediato al primo frame valido
                    }
                    else {
                        smoothedMidiVoice = alpha * currentMidi + (1.0f - alpha) * smoothedMidiVoice;
                    }

                    float smoothedHz = 440.0f * std::pow(2.0f, (smoothedMidiVoice - 69.0f) / 12.0f);
                    float perfectlyTunedPitch = snapToGrid(smoothedHz);

                    uiPitchVoice.store(perfectlyTunedPitch, std::memory_order_relaxed);
                }
            }
            else
            {
                // --- LA MODIFICA CRITICA: RESET DEI FILTRI NEL SILENZIO ---
                // Se la voce scende sotto la soglia RMS, azzeriamo la memoria.
                // Questo previene scivolamenti di pitch (portamento) tra una frase e l'altra.

                smoothedMidiVoice = -1.0f;
                lastSnappedMidiVoice = -1.0f;

                // Riempiamo il filtro mediano con 0.0f per uccidere code residue
                std::fill(pitchHistoryVoice.begin(), pitchHistoryVoice.end(), 0.0f);
            }

            samplesSinceLastAnalysisVoice = 0;
        }

        // 2. Process Guitar
        // 2. Process Guitar
        float guitarProcessed = applyGate(guitarIn[i], gateEnvGuitar, gateGainGuitar, gateReleaseCoeffGuitar);
        guitarProcessed = applyCompressor(guitarProcessed, compEnvGuitar);

        // APPLICAZIONE DEL LPF PER ISOLARE LA FONDAMENTALE
        lpfState = lpfState + lpfAlpha * (guitarProcessed - lpfState);
        float guitarFilteredForAnalysis = lpfState;

        applyEnvelopeFollower(guitarFilteredForAnalysis, envGuitar);

        // Salviamo il segnale FILTRATO nel buffer per l'analisi FFT
        circularBuffer[writeIndex] = guitarFilteredForAnalysis;

        writeIndex = (writeIndex + 1) % windowSize;
        samplesSinceLastAnalysis++;

        if (samplesSinceLastAnalysis >= hopSize)
        {
            for (int j = 0; j < windowSize; ++j)
            {
                frameGuitar[j] = circularBuffer[(writeIndex + j) % windowSize];
            }

            // CHORD PITCH DETECTION (HPS + WEIGHTING)
            float chordRoot = chordDetector.detectChordRoot(frameGuitar.data(), windowSize);

            // Focus on guitar range
            if (chordRoot >= 80.0f && chordRoot <= 800.0f)
            {
                // 1. Quantizzazione alla nota più vicina con isteresi
                float perfectlyTunedGuitar = snapToGridGuitar(chordRoot);

                // 2. Filtro Mediano a 5 frame per uccidere i glitch improvvisi (es. ottave errate)
                pitchHistoryGuitar.erase(pitchHistoryGuitar.begin());
                pitchHistoryGuitar.push_back(perfectlyTunedGuitar);

                std::copy(pitchHistoryGuitar.begin(), pitchHistoryGuitar.end(), sortedHistoryGuitar.begin());
                std::sort(sortedHistoryGuitar.begin(), sortedHistoryGuitar.end());

                float medianPitchGuitar = sortedHistoryGuitar[sortedHistoryGuitar.size() / 2];

                // 3. Output
                uiPitchGuitar.store(medianPitchGuitar, std::memory_order_relaxed);
            }

            samplesSinceLastAnalysis = 0;
        }

        // Output
        leftOut[i] = voiceProcessed;
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

// --- DSP IMPLEMENTATIONS ---

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
    float inputDB = 20.0f * std::log10(amplitude);

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

// --- PITCH DETECTION (YIN) ---

float MainComponent::detectPitchYIN(const float* audioBuffer, int bufferSize, double sampleRate)
{
    int tauMax = static_cast<int>(sampleRate / 60.0f);
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

// --- OSC & PRESETS ---

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

    gateThreshold = p.gateThreshold;
    compThreshold = p.compThreshold;
    compRatio = p.compRatio;
    compMakeupGain = p.compMakeupGain;
    envFollowerRelease = p.envFollowerRelease;

    envFollowerReleaseCoeff = std::exp(-1.0f / (envFollowerRelease * currentSampleRate));
    oscSender.send("/preset", presetIndex);

    juce::MessageManager::callAsync([this, presetIndex]()
        {
            presetLabel.setText("Preset: " + juce::String(presetIndex + 1), juce::dontSendNotification);
        });

    DBG("Preset loaded: " + juce::String(presetIndex + 1));
}

float MainComponent::snapToGrid(float pitchHz)
{
    if (pitchHz <= 0.0f) return 0.0f;

    float currentMidiNote = 69.0f + 12.0f * std::log2(pitchHz / 440.0f);

    if (lastSnappedMidiVoice < 0.0f) {
        lastSnappedMidiVoice = std::round(currentMidiNote);
    }
    else {
        // Soglia abbassata a 0.55 per permettere transizioni vocali naturali
        // mantenendo al contempo la stabilità sui confini
        if (std::abs(currentMidiNote - lastSnappedMidiVoice) > 0.55f) {
            lastSnappedMidiVoice = std::round(currentMidiNote);
        }
    }

    return 440.0f * std::pow(2.0f, (lastSnappedMidiVoice - 69.0f) / 12.0f);
}

float MainComponent::snapToGridGuitar(float pitchHz)
{
    if (pitchHz <= 0.0f) return 0.0f;

    float currentMidiNote = 69.0f + 12.0f * std::log2(pitchHz / 440.0f);

    if (lastSnappedMidiGuitar < 0.0f)
    {
        lastSnappedMidiGuitar = std::round(currentMidiNote);
    }
    else
    {
        // Aumenta la soglia a 1.2 semitoni o più. 
        // L'algoritmo deve essere *molto* sicuro per cambiare l'armonia di base.
        if (std::abs(currentMidiNote - lastSnappedMidiGuitar) > 0.8f)
        {
            lastSnappedMidiGuitar = std::round(currentMidiNote);
        }
    }

    return 440.0f * std::pow(2.0f, (lastSnappedMidiGuitar - 69.0f) / 12.0f);
}

void MainComponent::sendVocalPitchToSuperCollider(float pitchInHz)
{
	// If value is close to the last sent pitch, ignore it to prevent micro-fluctuations
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
	// Compute difference between consecutive pitch values in cents
    if (lastSentGuitarPitch > 0.0f && pitchInHz > 0.0f)
    {
        float centsDiff = 1200.0f * std::abs(std::log2(pitchInHz / lastSentGuitarPitch));

        // If variation is too small, ignore it
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