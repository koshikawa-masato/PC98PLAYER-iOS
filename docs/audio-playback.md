# Playback timing and pause diagnostics

A pause discards both pending software PCM and AudioQueue's scheduled/prefetched buffers. The allocated queue is reused, but resume waits for new guest PCM instead of replaying the old tail. Output starts with a 16 ms gain ramp. This intentionally skips the unheard queued tail when pausing; it does not rewind the guest sound-chip state.

On iOS, audio consumption drives guest frame production while the output queue exists. The producer aims for 80 ms of software PCM, in addition to the three hardware buffers. Up to eight guest frames may be generated per display tick to restore the reserve after a UI stall. When audio is unavailable, the previous wall-clock pacing remains in use. The reserve trades some audio latency for stability during layout changes.

If the callback still runs short, it does not emit alternating tiny PCM fragments and silence. It holds unread samples until at least 50 ms is available, then fades them in over 16 ms. The last output value decays to zero over 32 frames; no previously consumed source waveform is replayed.

## Physical-device capture

Debug builds accept `--audio-probe before`, `--audio-probe after`, or `--audio-probe rotation` with an already cached game. ReplayKit asks for app capture permission. Only app audio is written; video and microphone samples are discarded and microphone capture is disabled. No recording starts in ordinary launches. Release builds exclude the implementation and ReplayKit/CoreMedia debug linkage.

The probe writes `Documents/audio-probe-LABEL/reference.caf` (generated stereo PCM), `output.caf` (ReplayKit app output), and `report.json` (capture timestamps and UI events). Before/after mode performs three pause/resume cycles and fullscreen entry/exit. Rotation mode records until `Documents/audio-probe-rotation/stop.flag` exists, with a three-minute maximum; the physical orientation changes are performed by the tester. Framebuffer and speaker acoustics are not measured by these audio files.

Run `tools/analyze_audio_probe.py BEFORE_DIRECTORY AFTER_DIRECTORY OUTPUT_DIRECTORY --rotation ROTATION_DIRECTORY` with Python packages numpy, scipy, soundfile and matplotlib. The tool generates plots, WAV copies and a JSON analysis. The plotted windows compare resume 2/3 and fullscreen entry/exit. Resume 1 fell in a natural silence in this particular Rance IV run and is not used to claim improvement. Zero runs are observations, not automatically classified as defects. Source positions are reported only when normalized waveform correlation is at least 0.99.

## Evidence (2026-10-25)

On S9Plus (iPhone 16 Pro Max), the original recording had 28.07 ms / 27.87 ms silent intervals after resume, 28.96 ms / 27.91 ms after fullscreen entry, and 24.04 ms after fullscreen exit. The updated recording had no >=2 ms zero runs after sound began in those four 400 ms windows. The two updated resume segments matched the generated PCM with correlations 0.999981 and 0.999966; inferred start positions were within six 44.1 kHz samples of the post-pause source boundary. This supports fresh-source resume, but the original observation alone does not prove a literal replay of an already audible waveform.

The regression test covers 100 pause/resume cycles, disposal of old PCM, fresh priming, refill hysteresis, 16 ms fade configuration, audio-clock reserve decisions, state clear, error recovery and teardown callbacks. The iOS simulator tests cover keyboard input, state roundtrip, portrait/landscape layout, fullscreen roundtrip and Duo layout.

The later manual capture reported zero underrun frames over the app run and recorded a fullscreen entry. It did not log an orientation transition, so that recording is not evidence of portrait/landscape rotation coverage.
