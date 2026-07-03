defmodule Netmd.SimulatorTest do
  use ExUnit.Case, async: true

  alias Netmd.Disc
  alias Netmd.Simulator
  alias Netmd.Track

  defp open!(opts \\ []) do
    {:ok, device} = Netmd.open([transport: Simulator] ++ opts)
    device
  end

  test "list_content reads the demo disc through the whole stack" do
    device = open!()

    assert {:ok, disc} = Netmd.list_content(device)
    assert disc.title == "Demo Disc"
    assert disc.writable
    refute disc.write_protected
    assert disc.track_count == 2

    tracks = Disc.tracks(disc)
    assert Enum.map(tracks, & &1.title) == ["Opening", "Second Song"]
    assert Enum.map(tracks, & &1.encoding) == [:sp, :lp2]
    assert Enum.all?(tracks, &(&1.duration > 0))
  end

  test "device_status reports a ready disc" do
    device = open!()
    assert {:ok, status} = Netmd.device_status(device)
    assert status.disc_present
    assert status.state == :ready
  end

  test "playback controls change the reported state" do
    device = open!()
    assert :ok = Netmd.play(device)
    assert {:ok, %{state: :playing}} = Netmd.device_status(device)
    assert :ok = Netmd.pause(device)
    assert {:ok, %{state: :paused}} = Netmd.device_status(device)
    assert :ok = Netmd.stop(device)
    assert {:ok, %{state: :ready}} = Netmd.device_status(device)
  end

  test "renaming the disc is reflected in a fresh listing" do
    device = open!()
    assert :ok = Netmd.rename_disc(device, "My Mixtape")
    assert {:ok, disc} = Netmd.list_content(device)
    assert disc.title == "My Mixtape"
  end

  test "renaming a track is reflected in a fresh listing" do
    device = open!()
    assert :ok = Netmd.rename_track(device, 0, "Intro")
    assert {:ok, disc} = Netmd.list_content(device)
    assert [%{title: "Intro"} | _] = Disc.tracks(disc)
  end

  test "erasing a track removes it" do
    device = open!()
    assert :ok = Netmd.erase_track(device, 0)
    assert {:ok, disc} = Netmd.list_content(device)
    assert disc.track_count == 1
    assert [%{title: "Second Song"}] = Disc.tracks(disc)
  end

  test "moving a track reorders the disc" do
    device = open!()
    assert :ok = Netmd.move_track(device, 1, 0)
    assert {:ok, disc} = Netmd.list_content(device)
    assert Enum.map(Disc.tracks(disc), & &1.title) == ["Second Song", "Opening"]
  end

  test "downloading a track adds it and titles it" do
    device = open!()

    track = %Track{
      title: "New Song",
      format: :lp4,
      data: :binary.copy(<<0x11>>, 96),
      raw_key: <<1, 2, 3, 4, 5, 6, 7, 8>>
    }

    assert {:ok, %{track: 2, uuid: "SIMUUID0"}} = Netmd.download(device, track, settle_ms: 0)

    assert {:ok, disc} = Netmd.list_content(device)
    assert disc.track_count == 3
    assert List.last(Disc.tracks(disc)).title == "New Song"
    assert List.last(Disc.tracks(disc)).encoding == :lp4
  end

  test "a custom disc can be supplied at open" do
    disc = %Simulator.Disc{
      raw_title: "Field Recordings",
      tracks: [Simulator.Disc.track("Birds", 0x90, 0x00, {0, 1, 30, 0})]
    }

    device = open!(disc: disc)
    assert {:ok, listed} = Netmd.list_content(device)
    assert listed.title == "Field Recordings"
    assert listed.track_count == 1
  end

  test "an ejected disc reports no disc" do
    device = open!()
    assert :ok = Netmd.eject_disc(device)
    assert {:ok, status} = Netmd.device_status(device)
    refute status.disc_present
  end

  test "factory mode authenticates and yields a device code" do
    device = open!()
    assert {:ok, factory} = Netmd.factory(device)
    assert {:ok, "S2.100"} = Netmd.Factory.descriptive_device_code(factory)
  end
end
