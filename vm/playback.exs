# Playback controls over real USB, in the netmd VM.
#
# Starts the FunctionFS gadget, opens it with the real transport, and drives
# the playback controls, printing device status after each so the effect is
# visible. Run as root in the netmd VM:
#
#   sudo mix run vm/playback.exs

{:ok, _} = Application.ensure_all_started(:circuits_usb)
{:ok, _} = Application.ensure_all_started(:netmd)

vendor_id = 0x054C
product_id = 0x00C8

IO.puts("== starting gadget ==")
{:ok, gadget} = Netmd.Simulator.Gadget.start_link(udc: "dummy_udc.0")
Process.sleep(2500)

{:ok, device} = Netmd.open(vendor_id: vendor_id, product_id: product_id)
IO.puts("opened #{Netmd.Device.name(device)}")

show = fn label ->
  case Netmd.device_status(device) do
    {:ok, s} ->
      time =
        case s.time do
          %{minute: m, second: sec, frame: f} ->
            :io_lib.format("~2..0b:~2..0b+~3..0b", [m, sec, f]) |> to_string()

          nil ->
            "--"
        end

      IO.puts("  #{String.pad_trailing(label, 16)} state=#{s.state} track=#{s.track} time=#{time}")

    other ->
      IO.puts("  #{label}: #{inspect(other)}")
  end
end

drive = fn label, fun ->
  case fun.() do
    :ok -> show.(label)
    {:ok, _} -> show.(label)
    other -> IO.puts("  #{label} FAILED: #{inspect(other)}")
  end
end

IO.puts("== playback ==")
show.("initial")
drive.("play", fn -> Netmd.play(device) end)
drive.("pause", fn -> Netmd.pause(device) end)
drive.("fast_forward", fn -> Netmd.fast_forward(device) end)
drive.("rewind", fn -> Netmd.rewind(device) end)
drive.("next_track", fn -> Netmd.next_track(device) end)
drive.("next_track", fn -> Netmd.next_track(device) end)
drive.("previous_track", fn -> Netmd.previous_track(device) end)
drive.("goto_track 1", fn -> Netmd.goto_track(device, 1) end)
drive.("goto_time 1:23", fn -> Netmd.goto_time(device, 1, minute: 1, second: 23, frame: 45) end)
drive.("restart_track", fn -> Netmd.restart_track(device) end)
drive.("stop", fn -> Netmd.stop(device) end)

IO.puts("== teardown ==")
Netmd.close(device)
Netmd.Simulator.Gadget.stop(gadget)
IO.puts("PLAYBACK_OK")
