# Both sides of a NetMD USB link in one BEAM.
#
# Starts NetMD.Simulator.Gadget (the device, over FunctionFS on dummy_udc),
# waits for the dummy_hcd host side to enumerate it, then drives it with the
# REAL NetMD.Transport.Usb over usbfs -- exercising the whole library and the
# CircuitsUsb transport with no hardware. Run as root in the netmd VM:
#
#   sudo mix run vm/both_sides.exs
#
# It is deliberately chatty and tolerant: each step prints its outcome so a
# failure (e.g. the UDC assigning bulk endpoint addresses other than the
# 0x81/0x02 the transport expects) is a diagnostic, not a crash.

{:ok, _} = Application.ensure_all_started(:circuits_usb)
{:ok, _} = Application.ensure_all_started(:netmd)

vendor_id = 0x054C
product_id = 0x00C8

step = fn label, fun ->
  case fun.() do
    {:ok, value} ->
      IO.puts("  ok   #{label}")
      value

    :ok ->
      IO.puts("  ok   #{label}")
      :ok

    other ->
      IO.puts("  FAIL #{label}: #{inspect(other)}")
      other
  end
end

IO.puts("== device side: starting FunctionFS gadget ==")

{:ok, gadget} =
  NetMD.Simulator.Gadget.start_link(
    udc: "dummy_udc.0",
    vendor_id: vendor_id,
    product_id: product_id
  )

IO.puts("  gadget process #{inspect(gadget)}; waiting for host enumeration...")
Process.sleep(2500)

IO.puts("== host side: usbfs enumeration ==")

known =
  CircuitsUsb.list_devices()
  |> Enum.map(& &1.descriptor)
  |> Enum.filter(&match?({:ok, %{vendor_id: ^vendor_id, product_id: ^product_id}}, &1))

IO.puts("  found #{length(known)} matching device(s) on usbfs")

result =
  try do
    device = step.("open (real transport)", fn -> NetMD.open(vendor_id: vendor_id, product_id: product_id) end)

    case device do
      %NetMD.Device{} ->
        IO.puts("  device name: #{NetMD.Device.name(device)}")

        disc = step.("list_content", fn -> NetMD.list_content(device) end)

        if match?(%NetMD.Disc{}, disc) do
          IO.puts("    title=#{inspect(disc.title)} tracks=#{disc.track_count} writable=#{disc.writable}")

          for t <- NetMD.Disc.tracks(disc) do
            IO.puts("    - #{t.index}: #{inspect(t.title)} (#{t.encoding})")
          end
        end

        step.("device_status", fn -> NetMD.device_status(device) end)
        step.("rename_disc \"Made In A VM\"", fn -> NetMD.rename_disc(device, "Made In A VM") end)

        relisted = step.("list_content (after rename)", fn -> NetMD.list_content(device) end)
        if match?(%NetMD.Disc{}, relisted), do: IO.puts("    title now #{inspect(relisted.title)}")

        track = %NetMD.Track{title: "VM Upload", format: :lp4, data: :binary.copy(<<0x11>>, 96)}
        step.("download a track", fn -> NetMD.download(device, track, settle_ms: 0) end)

        after_dl = step.("list_content (after download)", fn -> NetMD.list_content(device) end)
        if match?(%NetMD.Disc{}, after_dl), do: IO.puts("    tracks now #{after_dl.track_count}")

        NetMD.close(device)
        :ok

      _ ->
        IO.puts("  could not open the device; is it enumerated with 0x81/0x02 bulk endpoints?")
        :error
    end
  rescue
    e ->
      IO.puts("  demo raised: #{Exception.message(e)}")
      :error
  end

IO.puts("== teardown ==")
NetMD.Simulator.Gadget.stop(gadget)
IO.puts(if result == :ok, do: "DEMO_OK", else: "DEMO_INCOMPLETE")
