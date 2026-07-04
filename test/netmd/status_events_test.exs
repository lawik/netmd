defmodule NetMD.StatusEventsTest do
  use ExUnit.Case, async: true

  # The managed transport over the in-process simulator, so the whole poll ->
  # diff -> notify path runs without hardware.
  defp open!(opts) do
    {:ok, device} =
      NetMD.open([transport: NetMD.Transport.Managed, base_transport: NetMD.Simulator] ++ opts)

    device
  end

  defp flush_status do
    receive do
      {:netmd_status, _} -> flush_status()
    after
      0 -> :ok
    end
  end

  test "a subscriber gets the current status, then again on change" do
    device = open!(status_event_poll: 30)

    assert :ok = NetMD.subscribe(device)
    assert_receive {:netmd_status, %{state: :ready}}, 1000

    assert :ok = NetMD.play(device)
    assert_receive {:netmd_status, %{state: :playing}}, 1000

    NetMD.close(device)
  end

  test "no events arrive after unsubscribing" do
    device = open!(status_event_poll: 30)

    NetMD.subscribe(device)
    assert_receive {:netmd_status, _}, 1000

    assert :ok = NetMD.unsubscribe(device)
    Process.sleep(60)
    flush_status()
    refute_receive {:netmd_status, _}, 200

    NetMD.close(device)
  end

  test "status_event_poll: false disables polling entirely" do
    device = open!(status_event_poll: false)

    NetMD.subscribe(device)
    refute_receive {:netmd_status, _}, 200

    NetMD.close(device)
  end

  test "an idle device stops emitting once the status settles" do
    device = open!(status_event_poll: 30)

    NetMD.subscribe(device)
    # The ready disc's status does not change, so exactly one event then quiet.
    assert_receive {:netmd_status, %{state: :ready}}, 1000
    refute_receive {:netmd_status, _}, 200

    NetMD.close(device)
  end

  test "subscribing is unavailable without the managed transport" do
    {:ok, device} = NetMD.open(transport: NetMD.Simulator)
    assert NetMD.subscribe(device) == {:error, :status_events_unavailable}
    NetMD.close(device)
  end
end
