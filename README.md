# Netmd

Drive Sony MiniDisc recorders over NetMD USB from Elixir. A port of
[netmd-js](https://github.com/cybercase/netmd-js) (the library behind
Web MiniDisc) cross-referenced against libnetmd from
[linux-minidisc](https://github.com/linux-minidisc/linux-minidisc),
running on [circuits_usb](https://github.com/lawik/circuits_usb).
Linux only, no native code beyond the circuits_usb NIF.

## What works

- Enumerate and open the ~48 known NetMD devices
- Disc listing: titles (half and full width Shift-JIS), groups, per-track
  encoding, duration and protection, capacity
- Playback control, seeking, eject
- Renaming discs and tracks, erasing and moving tracks
- Track download (recording to disc) through the secure session,
  including the open-source EKB and DES retail MAC key negotiation
- Track upload from an MZ-RH1, with AEA/WAV headers ready for ffmpeg
- Factory mode: direct RAM/EEPROM/peripheral access, firmware patching,
  raw UTOC sector read/write and the display override (dangerous; see
  `Netmd.Factory`)

## Usage

```elixir
{:ok, device} = Netmd.open()

{:ok, disc} = Netmd.list_content(device)
IO.puts("#{disc.title}: #{disc.track_count} tracks")

:ok = Netmd.play(device)
:ok = Netmd.rename_disc(device, "Mix Tape")

# Download audio: raw PCM (16-bit big-endian stereo, 44100 Hz) or
# pre-encoded ATRAC3 for the LP modes.
track = %Netmd.Track{title: "New Song", format: :lp2, data: atrac3_data}
{:ok, %{track: n}} = Netmd.download(device, track)

Netmd.close(device)
```

The facade delegates to layers that are usable on their own; see the
module docs of `Netmd.Commands`, `Netmd.Interface`, `Netmd.Session`,
`Netmd.Device`, `Netmd.Query` and `Netmd.Factory`.

## Running without hardware

`Netmd.Simulator` is a virtual NetMD device that decodes the protocol and
holds disc state, so the whole library runs in-process with no USB:

```elixir
{:ok, device} = Netmd.open(transport: Netmd.Simulator)
{:ok, disc} = Netmd.list_content(device)
```

To exercise the real usbfs transport too, `Netmd.Simulator.Gadget`
presents that same brain as an actual USB device over FunctionFS; with
`dummy_hcd` it and a host driving `Netmd.Transport.Usb` run in one VM.
See [`vm/README.md`](vm/README.md).

## Permissions

Accessing `/dev/bus/usb` needs root or a udev rule for your user, e.g.

    SUBSYSTEM=="usb", ATTRS{idVendor}=="054c", MODE="0666"

## Testing

The protocol layers are verified byte-for-byte against golden vectors
generated from netmd-js itself, and the full flows replay against a
scripted mock transport. See `TESTING.md`.

## Installation

```elixir
def deps do
  [
    {:netmd, github: "lawik/netmd"}
  ]
end
```

## License

GPL-2.0, matching the reference implementations this library ports.
