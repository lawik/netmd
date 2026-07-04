# Running netmd against a virtual device

Two ways to exercise the library without a real MiniDisc recorder:

## 1. In-process, no VM or root (`NetMD.Simulator`)

`NetMD.Simulator` is a `NetMD.Transport` that decodes the NetMD protocol
and holds disc state. The whole library runs against it in the BEAM:

```elixir
{:ok, device} = NetMD.open(transport: NetMD.Simulator)
{:ok, disc} = NetMD.list_content(device)
:ok = NetMD.rename_disc(device, "Mixtape")
{:ok, %{track: n}} = NetMD.download(device, %NetMD.Track{
  title: "New", format: :lp4, data: data
})
```

This is what the `test/netmd/simulator_test.exs` suite drives. No USB is
involved, so it will not catch bugs in the `CircuitsUsb` transport layer.

## 2. Real USB, both sides in one VM (`NetMD.Simulator.Gadget`)

To exercise the real usbfs transport, the simulator brain is presented as
an actual USB device through `CircuitsUsb.Gadget` + `CircuitsUsb.FunctionFs`
(FunctionFS, not raw-gadget). With `dummy_hcd` loaded, the gadget and a
host driving `NetMD.Transport.Usb` run in the same machine.

This needs root and a Linux gadget stack, so it runs in a throwaway VM
that reuses the circuits_usb harness (dummy_hcd, Elixir provisioning).

### Prerequisites (on the host running the VM)

`qemu-system-x86_64`, `qemu-img`, `genisoimage`, KVM, and a sibling
`../circuits_usb` checkout (the VM shares the parent directory, so both
repos are visible in the guest).

### Steps

```sh
vm/vm.sh up       # boot the VM (downloads an Ubuntu cloud image once)
vm/vm.sh setup    # kernel deps, gadget modules, dummy_hcd, Elixir (slow: OTP builds from source)
vm/vm.sh demo     # run vm/both_sides.exs as root
vm/vm.sh ssh      # a shell in the guest, if you want to poke around
vm/vm.sh down     # power off
vm/vm.sh destroy  # power off and delete the disk overlay
```

`vm/both_sides.exs` starts the gadget, waits for the host side to
enumerate it, then opens it with the real transport and runs
`list_content`, `rename_disc`, `download`, etc. It prints each step's
outcome and prints `DEMO_OK` on success.

### What runs where

| Piece | Side | Mechanism |
|-------|------|-----------|
| `NetMD.Simulator.Gadget` | device | FunctionFS over `dummy_udc.0` |
| `NetMD` facade + `NetMD.Transport.Usb` | host | usbfs over the `dummy_hcd` host bus |
| the kernel | link | `dummy_hcd` loops device ↔ host |

### Status

Verified in the circuits_usb VM (Ubuntu 6.8, dummy_hcd): the gadget
enumerates as a Sony NetMD device and the demo drives `list_content`,
`device_status`, `rename_disc` and a track `download` over real usbfs,
printing `DEMO_OK`. The host transport's expected bulk endpoints
(`0x81` IN, `0x02` OUT) came through unchanged on `dummy_udc`.

### Caveats

- `dummy_hcd` must be built against the running kernel. The circuits_usb
  harness fetches `dummy_hcd.c` for the kernel's `major.minor`; if the
  prebuilt `.ko` mismatches (symbol/version errors on `insmod`), delete
  `harness/modules/dummy_hcd/dummy_hcd.{c,ko}` and let it re-fetch.
- The OTP source build in `setup` takes 10-15 minutes the first time.
- If the demo reports it cannot open the device, check the enumerated
  descriptor (`lsusb -v`) in case a different UDC renumbered the bulk
  endpoints away from `0x81`/`0x02`.
