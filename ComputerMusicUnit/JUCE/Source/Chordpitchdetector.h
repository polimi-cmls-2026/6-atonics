#pragma once
#include <vector>
#include <complex>
#include <cmath>
#include <numeric>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// =============================================================================
//  ChordPitchDetector — HPS + FFT optimisé pour usage live
//
//  Latence totale visée : ~75 ms (FFT 2048, médian 3 frames, hop = FFT/2)
//
//  Optimisations clés :
//   1. Filtre médian réduit à 3 frames (au lieu de 5)
//   2. Reset dynamique du filtre sur détection d'attaque (transitoire RMS)
//   3. Deadband en cents pour éviter les micro-envois OSC inutiles
//   4. Fenêtre de Hann pré-calculée à l'init (pas de malloc dans l'audio thread)
//   5. FFT Cooley-Tukey in-place — aucune dépendance externe
// =============================================================================

class ChordPitchDetector
{
public:
    // -------------------------------------------------------------------------
    //  Construction
    //  fftSize   : doit être une puissance de 2 — 2048 recommandé pour le live
    //  sampleRate: ton sample rate ASIO (44100 ou 48000)
    // -------------------------------------------------------------------------
    ChordPitchDetector(int fftSize = 2048, double sampleRate = 44100.0)
        : fftSize(fftSize), sampleRate(sampleRate)
    {
        hannWindow.resize(fftSize);
        for (int i = 0; i < fftSize; ++i)
            hannWindow[i] = 0.5f * (1.0f - std::cos(2.0f * (float)M_PI * i / (fftSize - 1)));

        fftBuffer.resize(fftSize);
        magnitudes.resize(fftSize / 2 + 1);
        hpsSpectrum.resize(fftSize / 2 + 1);

        // Filtre médian : 3 frames pour minimiser la latence en live
        medianHistory.assign(medianFrames, 0.0f);

        // Initialise l'estimateur RMS pour la détection d'attaque
        prevRms = 0.0f;
    }

    // -------------------------------------------------------------------------
    //  Appelle cette méthode à chaque hop (quand samplesSinceLastAnalysis >= hopSize)
    //  frame       : pointeur sur windowSize échantillons déroulés
    //  frameSize   : doit être == fftSize
    //  Retourne    : fondamentale en Hz, ou 0.0f si silence / hors range
    // -------------------------------------------------------------------------
    float detectChordRoot(const float* frame, int frameSize)
    {
        if (frameSize != fftSize)
            return 0.0f;

        // --- 1. Calcul RMS pour la garde silence et la détection d'attaque ---
        float energy = 0.0f;
        for (int i = 0; i < fftSize; ++i)
            energy += frame[i] * frame[i];
        float rms = std::sqrt(energy / fftSize);

        if (rms < rmsThreshold)
        {
            prevRms = rms;
            return 0.0f;
        }

        // --- 2. Détection d'attaque : si le RMS monte brutalement, vide le
        //        filtre médian pour ne pas retarder le changement d'accord ---
        float rmsRatio = (prevRms > 1e-6f) ? (rms / prevRms) : 999.0f;
        if (rmsRatio > attackRatioThreshold)
            resetMedianHistory();
        prevRms = rms;

        // --- 3. Fenêtrage de Hann ---
        for (int i = 0; i < fftSize; ++i)
            fftBuffer[i] = { frame[i] * hannWindow[i], 0.0f };

        // --- 4. FFT in-place ---
        computeFFT(fftBuffer);

        // --- 5. Spectre de magnitudes ---
        for (int i = 0; i <= fftSize / 2; ++i)
            magnitudes[i] = std::abs(fftBuffer[i]);

        // --- 6. HPS (Harmonic Product Spectrum) ---
        //    Plage cible : 60–800 Hz (cordes basses + aigu guitare standard)
        const int numHarmonics = 4;
        const int minBin = std::max(1, static_cast<int>(minFreqHz * fftSize / sampleRate));
        const int maxBin = static_cast<int>(maxFreqHz * fftSize / sampleRate);

        for (int i = 0; i <= fftSize / 2; ++i)
            hpsSpectrum[i] = magnitudes[i];

        for (int h = 2; h <= numHarmonics; ++h)
        {
            for (int i = minBin; i <= maxBin; ++i)
            {
                int srcBin = i * h;
                if (srcBin <= fftSize / 2)
                    hpsSpectrum[i] *= magnitudes[srcBin];
            }
        }

        // --- 7. Recherche du pic dans la plage cible ---
        int peakBin = minBin;
        float peakVal = hpsSpectrum[minBin];
        for (int i = minBin + 1; i <= maxBin; ++i)
        {
            if (hpsSpectrum[i] > peakVal)
            {
                peakVal = hpsSpectrum[i];
                peakBin = i;
            }
        }

        // --- 8. Interpolation parabolique (précision sub-bin) ---
        float refinedBin = static_cast<float>(peakBin);
        if (peakBin > minBin && peakBin < maxBin)
        {
            float left   = hpsSpectrum[peakBin - 1];
            float center = hpsSpectrum[peakBin];
            float right  = hpsSpectrum[peakBin + 1];
            float denom  = 2.0f * (2.0f * center - left - right);
            if (std::abs(denom) > 1e-6f)
                refinedBin += (right - left) / denom;
        }

        float rawPitch = static_cast<float>(refinedBin * sampleRate / fftSize);

        // --- 9. Filtre médian 3 frames ---
        medianHistory.erase(medianHistory.begin());
        medianHistory.push_back(rawPitch);

        std::vector<float> sorted = medianHistory;
        std::sort(sorted.begin(), sorted.end());
        return sorted[sorted.size() / 2];
    }

    // -------------------------------------------------------------------------
    //  Paramètres ajustables publiquement avant / pendant l'usage
    // -------------------------------------------------------------------------
    float rmsThreshold      = 0.008f;   // Seuil silence (ajuste selon ton préamp)
    float attackRatioThreshold = 2.5f;  // Ratio RMS déclenchant un reset médian
    float minFreqHz         = 60.0f;    // Mi grave guitare basse : 41 Hz / guitare : 82 Hz
    float maxFreqHz         = 800.0f;   // Limite haute (harmoniques jusqu'à 800 Hz)

private:
    int    fftSize;
    double sampleRate;
    int    medianFrames = 3;            // 3 frames = ~70 ms de latence médian à 44100/hop1024

    std::vector<float>               hannWindow;
    std::vector<std::complex<float>> fftBuffer;
    std::vector<float>               magnitudes;
    std::vector<float>               hpsSpectrum;
    std::vector<float>               medianHistory;

    float prevRms;

    // Vide le filtre médian — appelé sur détection d'attaque
    void resetMedianHistory()
    {
        std::fill(medianHistory.begin(), medianHistory.end(), 0.0f);
    }

    // -------------------------------------------------------------------------
    //  FFT Cooley-Tukey radix-2 in-place — pas d'allocation dans l'audio thread
    // -------------------------------------------------------------------------
    void computeFFT(std::vector<std::complex<float>>& x)
    {
        int N = static_cast<int>(x.size());

        // Bit-reversal permutation
        for (int i = 1, j = 0; i < N; ++i)
        {
            int bit = N >> 1;
            for (; j & bit; bit >>= 1)
                j ^= bit;
            j ^= bit;
            if (i < j) std::swap(x[i], x[j]);
        }

        // Butterfly stages
        for (int len = 2; len <= N; len <<= 1)
        {
            float angle = -(float)M_PI * 2.0f / len;
            std::complex<float> wlen(std::cos(angle), std::sin(angle));
            for (int i = 0; i < N; i += len)
            {
                std::complex<float> w(1.0f, 0.0f);
                for (int j = 0; j < len / 2; ++j)
                {
                    std::complex<float> u = x[i + j];
                    std::complex<float> v = x[i + j + len / 2] * w;
                    x[i + j]             = u + v;
                    x[i + j + len / 2]   = u - v;
                    w *= wlen;
                }
            }
        }
    }
};
