# Flatroom

**Free, open-source, system-wide room correction for macOS.** Flatroom applies your room-correction filter to everything your Mac plays: music, video, browsers, games. It uses linear- or minimum-phase FIR convolution and needs no virtual audio driver. Measure your speakers with [REW](https://www.roomeqwizard.com) and Flatroom does the rest.

It is a lightweight alternative to commercial speaker-calibration suites such as Sonarworks SoundID Reference, Dirac Live or IK ARC. You bring the measurement; Flatroom plays everything through the correction.

## Features

- **System-wide, no driver.** Flatroom captures every app's audio headed to your interface with a Core Audio process tap, corrects it and plays it back to the same device. There is no kernel extension, no virtual device and nothing new in Sound settings. If Flatroom quits, the original audio comes straight back.
- **Real FIR convolution.** It uses uniformly partitioned convolution (Accelerate/vDSP) with filters of any length, at 44.1 to 192 kHz with a filter per sample rate. Linear phase keeps phase intact; minimum phase gives low latency.
- **A profile per output.** Your interface gets its room filter while your headphones or laptop speakers stay untouched. If the system output has no profile, apps that play directly to a profiled interface are still corrected.
- **Loudness-matched bypass** for honest A/B comparisons.
- **Volume keys and a native-looking HUD.** Volume is applied after the correction, in software, so the filter's headroom is kept.
- **Apps that play directly.** Choose apps such as DAWs (GarageBand is the default) that skip the correction and its latency.
- **Calls stay in sync.** Any app that records and plays at the same time (Teams, Zoom, Meet, WhatsApp, FaceTime) plays uncorrected while the call lasts, so lip sync and echo cancellation keep working.
- **Bit-perfect rate for Apple Music.** Flatroom switches the interface to each track's own sample rate (44.1, 48, 96 or 192 kHz) so macOS doesn't resample it. The current rate is shown in the menu bar.

| Filter type | Latency (typical) | Use |
|---|---|---|
| Linear phase (~0.7 s FIR) | ~350 ms | Music, critical listening |
| Minimum phase (~0.35 s FIR) | ~11 ms | Video, games, everyday use |

## Requirements

- **macOS 26 Tahoe or later**, tested on macOS 27 with Apple Silicon. Per-app exclusions and call detection need macOS 26. The core may run on macOS 14.2 or later, but that is untested.
- **To build:** Xcode 26 or its Command Line Tools.
- **For measuring:** a measurement microphone (a UMIK-1 or similar) and REW.

## Install

### Homebrew

```bash
brew install taguirrer/tap/flatroom
```

The formula builds Flatroom from source. Then link the app into your Applications folder:

```bash
mkdir -p ~/Applications
ln -sf "$(brew --prefix flatroom)/Flatroom.app" ~/Applications/
```

### From source

```bash
git clone https://github.com/taguirrer/flatroom.git
cd flatroom
scripts/build-app.sh --install
```

### Permissions

macOS asks for two permissions:

- **System Audio Recording**, the first time correction starts. Flatroom needs it to read the audio it corrects.
- **Accessibility**, which is optional: it is only needed for the volume keys.

Builds that aren't signed with a stable certificate are treated as a new app after each update, so macOS asks again. To avoid this, create a self-signed code-signing certificate named `Flatroom Dev`. In Keychain Access, use *Certificate Assistant → Create a Certificate…* with Type *Code Signing*. `scripts/sign.sh` uses it automatically.

## Make a filter

Filters live in `~/Library/Application Support/Flatroom/Filters/<name>/`. Assign one to an output in **Output profiles**.

### Option A: from a REW measurement (recommended)

Step by step in **[Measuring your room with REW](docs/measuring.md)**. In short:

1. Quit Flatroom, then measure each speaker at your listening position with REW, ideally at several positions around your head.
2. Export each measurement with *File → Export → Measurement as text*.
3. Design the filter:

```bash
cd filter-design
uv run python design_fir.py --left L-*.txt --right R-*.txt --name my-room
```

The script averages several positions per speaker. With one position, use `--measurement left.txt right.txt`.

The filter appears in Flatroom right away, with a `response.png` showing the measured and predicted responses. Useful options:

- `--phase linear`
- `--max-boost 6` and `--max-cut 9` (dB)
- `--bass-db 3`, for a target with more bass
- `--hf-from 500 --hf-amount 0.5`, to correct only the trend above 500 Hz
- `--boost-min-hz 30`

Run `--help` for the full list.

### Option B: import an impulse response

Already have a correction filter from REW (*EQ → Export filter impulse response*), rePhase, DRC or anything else that writes WAV? Choose **Output profiles → Import Filter…** and pick the WAV files:

- **Files:** one file, or one per sample rate. Mono files apply to both channels.
- **Missing rates** are resampled from the highest-rate file, so export at 192 kHz when you can.

### Filter format

A filter is a folder containing `fir_<rate>.wav` files (float32, one channel per speaker) and a `meta.json` with `gain_db`, `bypass_gain_db` and `files.<rate>.latency_samples`. See `Sources/AudioEngine/ConvolutionEngine.swift`.

## Privacy

Flatroom never touches the network. To follow Apple Music's sample rate, it reads Music's own log messages on your Mac (`log stream`).

## Support Flatroom

Flatroom is free and stays free. If it saves you a subscription, consider [sponsoring it](https://github.com/sponsors/taguirrer). Once sponsorships reach about €100 a year, they will pay for an Apple Developer account. That brings signed, notarized releases: one-click install, no Gatekeeper warnings, and permissions kept across updates.

## License

[GPL-3.0](LICENSE). Flatroom is not affiliated with Sonarworks, Dirac, IK Multimedia or Apple; their names are trademarks of their owners.

**Careful with volume:** start low after loading a new filter. Corrections can boost some frequencies by several dB.
