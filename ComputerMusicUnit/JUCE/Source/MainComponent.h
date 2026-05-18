#pragma once

#include <JuceHeader.h>
#include <juce_osc/juce_osc.h>
#define _USE_MATH_DEFINES
#include <cmath>
#include <vector>
#include <array>

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
    // Aggiungi il terzo parametro per il Gain
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
    int hopSize = 512;
    int samplesSinceLastAnalysis = 0;
    double currentSampleRate = 44100.0;

    // --- Audio Analysis Buffer (Voice) ---
    std::vector<float> circularBufferVoice;
    int writeIndexVoice = 0;
    int samplesSinceLastAnalysisVoice = 0;
    float detectedPitchVoice = 0.0f;

    // Nuova variabile per il filtro mediano
    std::vector<float> pitchHistoryVoice;

    // --- Nuove Funzioni ---
    float snapToGrid(float pitchHz);
    void sendVocalPitchToSuperCollider(float pitchInHz);

    // --- Noise Gate ---
    float gateThreshold = 0.01f;
    float gateAttack = 0.002f;
    float gateAttackCoeff = 0.0f;

    // Parametri separati per il Release
    float gateReleaseGuitar = 0.05f;
    float gateReleaseVoice = 0.2f;
    float gateReleaseCoeffGuitar = 0.0f;
    float gateReleaseCoeffVoice = 0.0f;

    // Variabili di stato
    float gateEnvGuitar = 0.0f;
    float gateEnvVoice = 0.0f;
    float gateGainGuitar = 0.0f;
    float gateGainVoice = 0.0f;

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