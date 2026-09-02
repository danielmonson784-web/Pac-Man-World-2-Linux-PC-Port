# Volume and mute silently do nothing on the ALSA, PulseAudio and WASAPI backends

**Upstream:** dolphin-emu/dolphin (`Source/Core/AudioCommon/`)
**Also affects:** ExpansionPak/ModernGekko, which vendors this code

## Summary

`SoundStream::SetVolume` is a no-op default:

```cpp
// Source/Core/AudioCommon/SoundStream.h:22
virtual void SetVolume(int) {}
```

`AudioCommon::UpdateSoundStream` is the only thing that applies the user's
volume/mute setting, and it does so exclusively through that virtual:

```cpp
const int volume =
    Config::Get(Config::MAIN_AUDIO_MUTED) ? 0 : Config::Get(Config::MAIN_AUDIO_VOLUME);
sound_stream->SetVolume(volume);
```

Three shipped backends never override it:

| Backend | Overrides `SetVolume`? |
|---|---|
| Cubeb | yes |
| OpenAL | yes |
| OpenSLES | yes |
| NullSound | yes |
| **ALSA** | **no** |
| **PulseAudio** | **no** |
| **WASAPI** | **no** |

On those three, moving the volume slider or ticking Mute changes the config and
changes nothing audible. There is no error and no log line — it just doesn't
work.

Cubeb is the default where it is valid, so most users never hit this. It bites
anyone who explicitly selects ALSA, PulseAudio or WASAPI, and on Linux ALSA is
also the automatic fallback when Cubeb is unavailable.

## Suggested fix

Rather than implementing `SetVolume` three more times against three different
platform APIs, apply the gain once in the mixer, where it is backend-agnostic.

`Mixer.h`:

```cpp
void SetMasterVolume(int volume) { m_master_volume.store(volume, std::memory_order_relaxed); }
...
std::atomic<int> m_master_volume{100};
```

`Mixer::Mix()`, after all the `MixerFifo` mixes and before the return:

```cpp
const int volume = m_master_volume.load(std::memory_order_relaxed);
if (volume != 100)
{
  for (std::size_t i = 0; i < num_samples * 2; ++i)
    samples[i] = static_cast<s16>(
        std::clamp((static_cast<int>(samples[i]) * volume) / 100, -32768, 32767));
}
```

`AudioCommon::UpdateSoundStream`, alongside the existing call:

```cpp
sound_stream->SetVolume(volume);
if (Mixer* mixer = sound_stream->GetMixer())
  mixer->SetMasterVolume(volume);
```

Notes on the shape of this:

- It is a no-op at volume 100, so the default path costs one atomic load and a
  compare per buffer.
- Keeping `SetVolume` as well means backends that *do* have native volume
  control still use it; the mixer gain only becomes visible on the ones that
  don't. Backends that implement both would double-attenuate, so if that is a
  concern the cleaner variant is to drop the virtual entirely and let the mixer
  own master volume for everyone.
- `MixSurround` already calls `Mix` internally, so it is covered.

## One gap in the above

`Mixer::MixWiimoteSpeaker` does **not** go through `Mix`, so Wiimote speaker
audio would still ignore volume and mute. That path should get the same gain
applied if this approach is taken.

## Environment

Linux, PulseAudio backend.

The broken behaviour is established by inspection: `SetVolume` is an empty
virtual in `SoundStream.h`, `UpdateSoundStream` is its only caller, and
`ALSA`/`PulseAudio`/`WASAPI` contain no override (grep finds no occurrence of
`SetVolume` in any of the three).

The proposed fix is verified by measurement. Recording the output sink and
taking per-second RMS over the same boot sequence:

| `[DSP] Volume` | peak output RMS |
|---|---|
| 100 | 2231 |
| 50 | 1095 |

Ratio 0.49, i.e. the gain applies linearly as expected. Before the fix the same
config change produced no measurable difference on this backend.
