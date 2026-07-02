# Research notes

Open-source examples and product patterns worth copying carefully.

## Whispering / Epicenter

Repository: https://github.com/EpicenterHQ/epicenter/tree/main/apps/whispering

Useful ideas:

- Core loop is exactly our target: press shortcut, speak, get text.
- It can copy and paste at the cursor, not only copy to clipboard.
- It supports local providers and cloud providers, so the engine boundary matters.
- It treats local transcription as private and free, but slower than cloud options.
- It has voice activity detection as a power-user mode.
- It supports AI transformations after transcription.

What we copied into this MVP:

- Configurable hotkey.
- Clipboard-first workflow.
- Optional paste-after-copy.
- A clean transcription engine setting so we can add or switch providers.

## whisper.cpp

Repository: https://github.com/ggml-org/whisper.cpp

Useful ideas:

- Very strong path for local/offline transcription.
- Optimized for Apple Silicon via Metal/Core ML.
- Provides `whisper-cli`, which can transcribe 16-bit WAV files.

What we copied into this MVP:

- The recorder writes 16 kHz mono 16-bit WAV.
- Optional `engine = "whisper_cpp"` settings are ready for a later speed-focused setup.

## Buzz

Repository: https://github.com/chidiwilliams/buzz

Useful ideas:

- Mature offline transcription app with multiple backends.
- Has live microphone transcription and transcript history/export features.
- Confirms that Python-based desktop transcription is viable, but a full GUI becomes a bigger app quickly.

What we copied into this MVP:

- Keep this first app small and scriptable.
- Add optional local transcript history, but keep it off by default for privacy.

## Plaud and Wispr Flow product lessons

These are not open-source codebases, but the product behavior is useful:

- Plaud is good at capturing thoughts and keeping a searchable history.
- Wispr Flow is good at low-friction dictation directly into whatever app you are using.

Near-term roadmap:

1. Get the hotkey-to-clipboard MVP reliable.
2. Add optional paste-at-cursor mode.
3. Add a small local history browser.
4. Add VAD hands-free mode.
5. Add optional text cleanup/transformation, preferably with a local LLM or directly chosen provider.
