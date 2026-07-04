# Probe the NetMD interrupt IN endpoint (0x83) and log whatever it emits.
#
# Every known NetMD device exposes an interrupt IN endpoint that the driver
# never reads; netmd-js and libnetmd learn "reply ready" by control polling
# instead. Software-driven operations (status, play, seek, track change) leave
# it silent, and the kernel already polls it ~100x/s, so a NAK every time means
# an idle endpoint. The one untested trigger is the unit's own front panel.
#
# Run it, then press buttons ON THE DEVICE (play, stop, track, volume, hold,
# the disc door) and watch for a "*** PACKET ***" line.
#
#   mix run tools/probe_interrupt.exs           # watch for 30s
#   mix run tools/probe_interrupt.exs 60         # watch for 60s
#   mix run tools/probe_interrupt.exs 60 0x83    # explicit endpoint
#
# Opens the bare USB engine (no reconnect manager). Needs /dev/bus/usb access
# (root or a udev rule). Closing resets the device, so it re-enumerates once
# when the probe ends -- harmless.

defmodule Probe do
  @length 16

  def run(seconds, endpoint) do
    case NetMD.open(reconnect: false) do
      {:ok, device} ->
        watch(device, endpoint, seconds)

      {:error, reason} ->
        log("open failed: #{inspect(reason)} (needs /dev/bus/usb access; try sudo)")
    end
  end

  defp watch(device, endpoint, seconds) do
    engine = device.handle
    log("opened #{NetMD.Device.name(device)}")
    log("initial status: #{inspect(NetMD.device_status(device))}")

    log(
      "watching interrupt ep 0x#{hex(endpoint)} for #{seconds}s -- " <>
        "press buttons ON THE DEVICE now"
    )

    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    {:ok, ref} = arm(engine, endpoint)
    count = loop(engine, endpoint, ref, deadline, 0)

    log("done: #{count} packet(s) seen on ep 0x#{hex(endpoint)}; closing (device will reset)")
    NetMD.close(device)
  end

  # One :infinity URB stays armed; the receive `after` just prints a heartbeat
  # without disturbing it, so a packet is logged the instant it arrives.
  defp loop(engine, endpoint, ref, deadline, count) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      _ = CircuitsUsb.cancel(engine, ref)
      count
    else
      receive do
        {:circuits_usb, ^ref, {:ok, data}} ->
          log("*** PACKET *** ep 0x#{hex(endpoint)} <- #{byte_size(data)}B  #{Base.encode16(data)}")
          {:ok, ref2} = arm(engine, endpoint)
          loop(engine, endpoint, ref2, deadline, count + 1)

        {:circuits_usb, ^ref, {:error, reason}} ->
          log("read ended: #{inspect(reason)} (device reset/disconnected?)")
          count
      after
        min(2000, remaining) ->
          log("...watching, #{div(remaining, 1000)}s left")
          loop(engine, endpoint, ref, deadline, count)
      end
    end
  end

  defp arm(engine, endpoint) do
    CircuitsUsb.submit(engine, {:interrupt_in, endpoint, @length}, timeout: :infinity, reply_to: self())
  end

  defp hex(byte), do: Integer.to_string(byte, 16)

  defp log(msg), do: IO.puts("[#{time()}] #{msg}")

  defp time() do
    {_, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0b:~2..0b:~2..0b", [h, m, s]) |> IO.iodata_to_binary()
  end
end

parse_int = fn
  "0x" <> hex -> String.to_integer(hex, 16)
  dec -> String.to_integer(dec)
end

{seconds, endpoint} =
  case System.argv() do
    [] -> {30, 0x83}
    [secs] -> {String.to_integer(secs), 0x83}
    [secs, ep] -> {String.to_integer(secs), parse_int.(ep)}
  end

Probe.run(seconds, endpoint)
