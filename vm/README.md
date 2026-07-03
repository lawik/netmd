# Running netmd against a virtual device

Two ways to exercise the library without a real MiniDisc recorder:

## 1. In-process, no VM or root (`Netmd.Simulator`)

`Netmd.Simulator` is a `Netmd.Transport` that decodes the NetMD protocol
and holds disc state. The whole library runs against it in the BEAM:

```elixir
{:ok, device} = Netmd.open(transport: Netmd.Simulator)
{:ok, disc} = Netmd.list_content(device)
:ok = Netmd.rename_disc(device, "Mixtape")
{:ok, %{track: n}} = Netmd.download(device, %Netmd.Track{
  title: "New", format: :lp4, data: data
})
```

This is what the `test/netmd/simulator_test.exs` suite drives. No USB is
involved, so it will not catch bugs in the `CircuitsUsb` transport layer.

## 2. Real USB, both sides in one VM (`Netmd.Simulator.Gadget`)

To exercise the real usbfs transport, the simulator brain is presented as
an actual USB device through `CircuitsUsb.Gadget` + `CircuitsUsb.FunctionFs`
(FunctionFS, not raw-gadget). With `dummy_hcd` loaded, the gadget and a
host driving `Netmd.Transport.Usb` run in the same machine.

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
| `Netmd.Simulator.Gadget` | device | FunctionFS over `dummy_udc.0` |
| `Netmd` facade + `Netmd.Transport.Usb` | host | usbfs over the `dummy_hcd` host bus |
| the kernel | link | `dummy_hcd` loops device ↔ host |

### Caveats

- The host `Netmd.Transport.Usb` expects the NetMD bulk endpoints at
  `0x81` (IN) and `0x02` (OUT), matching real hardware. The gadget
  requests those addresses, but a UDC may renumber them; if the demo
  reports it cannot open the device, check the enumerated descriptor
  (`lsusb -v`) and reconcile the addresses.
- The OTP source build in `setup` takes 10-15 minutes the first time.
- This VM path has not been run from the development host it was written
  on; treat the first `demo` run as the validation step.
