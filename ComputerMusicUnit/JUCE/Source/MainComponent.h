#pragma once

#include <JuceHeader.h>
#include <juce_osc/juce_osc.h>
#define _USE_MATH_DEFINES
#include <cmath>
#include <vector>
#include <array>
#include <atomic>
#include "Chordpitchdetector.h"

//==============================================================================
class MainComponent : public juce::AudioAppComponent,
    public juce::OSCReceiver::Listener<juce::OSCReceiver::MessageLoopCallback>,
    public juce::Timer
{
public:
    MainComponent();
    ~MainComponent() override;

    void prepareToPlay(int samplesPerBlockExpected, double sampleRate) override;
    void getNextAudioBlock(const juce::AudioSourceChannelInfo& bufferToFill) override;
    void releaseResources() override;

    void paint(juce::Graphics& g) override;
    void resized() override;

    void timerCallback() override;
    void oscMessageReceived(const juce::OSCMessage& message) override;

private:
    // --- DSP Functions ---
    float applyGate(float inputSample, float& envelope, float& gainState, float releaseCoeff);
    float applyCompressor(float inputSample, float& envelope);
    float applyEnvelopeFollower(float inputSample, float& envelope);
    float detectPitchYIN(const float* audioBuffer, int bufferSize, double sampleRate);

    void loadPreset(int presetIndex);
    void sendPitchToSuperCollider(float pitchInHz);

    // --- Audio Analysis Buffer (Overlapping Window) ---
    std::vector<float> circularBuffer;
    int writeIndex = 0;
    int windowSize = 2048;
    int hopSize = 1024;
    int samplesSinceLastAnalysis = 0;
    double currentSampleRate = 44100.0;

	// Pre-allocated vectors for guitar analysis
    std::vector<float> frameGuitar;
    std::vector<float> sortedHistoryGuitar;

    // --- Audio Analysis Buffer (Voice) ---
    std::vector<float> circularBufferVoice;
    int writeIndexVoice = 0;
    int samplesSinceLastAnalysisVoice = 0;
    float detectedPitchVoice = 0.0f;

    // Pre-allocated vectors for vocal analysis
    std::vector<float> frameVoice;
    std::vector<float> sortedHistoryVoice;

    // Variable for hysteresis
    float lastSnappedMidiVoice = -1.0f;
    float lastSnappedMidiGuitar = -1.0f;

	// Variable for median filtering
    std::vector<float> pitchHistoryVoice;

    std::vector<float> pitchHistoryGuitar;

    std::atomic<float> uiPitchVoice{ 0.0f };
    std::atomic<float> uiPitchGuitar{ 0.0f };

    float snapToGrid(float pitchHz);
    float snapToGridGuitar(float pitchHz);
    void sendVocalPitchToSuperCollider(float pitchInHz);

    float smoothedMidiVoice = -1.0f;

    // --- Noise Gate ---
    float gateThreshold = 0.01f;
    float gateAttack = 0.002f;
    float gateAttackCoeff = 0.0f;

    // Separated release times
    float gateReleaseGuitar = 0.05f;
    float gateReleaseVoice = 0.2f;
    float gateReleaseCoeffGuitar = 0.0f;
    float gateReleaseCoeffVoice = 0.0f;

    // State variables
    float gateEnvGuitar = 0.0f;
    float gateEnvVoice = 0.0f;
    float gateGainGuitar = 0.0f;
    float gateGainVoice = 0.0f;

    // --- Deadband State ---
    float lastSentGuitarPitch = -1.0f;
    float lastSentVoicePitch = -1.0f;
    float deadbandCents = 30.0f; // Tolerance for guitar

    // LPF for guitar analysus
    float lpfState = 0.0f;
	float lpfCutoffHz = 350.0f; // Set desired cutoff frequency
    float lpfAlpha = 0.0f;

    // --- Compressor ---
    float compThreshold = -20.0f;
    float compRatio = 4.0f;
    float compAttack = 0.01f;
    float compRelease = 0.1f;
    float compMakeupGain = 1.5f;
    float compAttackCoeff = 0.0f;
    float compReleaseCoeff = 0.0f;
    float compEnvGuitar = 0.0f;
    float compEnvVoice = 0.0f;

    // --- Envelope Follower ---
    float envFollowerAttack = 0.002f;
    float envFollowerRelease = 0.05f;
    float envFollowerAttackCoeff = 0.0f;
    float envFollowerReleaseCoeff = 0.0f;
    float envGuitar = 0.0f;
    float envVoice = 0.0f;

    // --- Pitch Detection (YIN specific) ---
    float detectedPitch = 0.0f;
    float yinThreshold = 0.15f;

	// HPS Pitch Detector for Chord Detection
    ChordPitchDetector chordDetector{ 2048, 8192, 44100.0 };

    // --- OSC ---
    juce::OSCSender   oscSender;
    juce::OSCReceiver oscReceiver;
    static constexpr int oscSendPort = 57120;
    static constexpr int oscReceivePort = 9000;
    const juce::String oscSendHost = "127.0.0.1";

    // --- Presets ---
    struct Preset
    {
        float gateThreshold;
        float compThreshold;
        float compRatio;
        float compMakeupGain;
        float envFollowerRelease;
    };

    std::array<Preset, 3> presets =
    { {
        { 0.01f,  -20.0f,  2.0f, 1.2f, 0.3f },
        { 0.02f,  -15.0f,  6.0f, 1.8f, 0.2f },
        { 0.005f, -10.0f, 10.0f, 2.0f, 0.5f }
    } };

    int currentPreset = 0;
    juce::Label presetLabel;

    juce::TextButton settingsButton;

    juce::Label pitchDebugLabel;
    juce::Label envDebugLabel;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(MainComponent)
};