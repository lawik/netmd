defmodule Netmd.CommandsTest do
  use ExUnit.Case, async: true

  alias Netmd.Audio
  alias Netmd.Commands
  alias Netmd.Device
  alias Netmd.Disc
  alias Netmd.MockTransport
  alias Netmd.Query

  @clean_poll {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}

  defp exchange(command, reply, reply_status \\ 0x09) do
    length = byte_size(reply) + 1

    [
      {{:control_out, 0x80, <<0x00>> <> command}, :ok},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, length, 0>>}},
      {{:control_in, 0x81, length}, {:ok, <<reply_status>> <> reply}},
      @clean_poll
    ]
  end

  defp descriptor(descriptor_hex, action_hex) do
    command = Query.format("1808 #{descriptor_hex} #{action_hex} 00")
    exchange(command, command)
  end

  test "device_status combines status, playback and position" do
    status_command = Query.format("1809 8001 0230 8800 0030 8804 00 ff00 00000000")

    status_reply =
      Query.format("1809 8001 0230 8800 0030 8804 00 1000 00090000 %x", [
        <<0, 0, 0, 0, 0x40, 0, 0, 0>>
      ])

    playback_command =
      Query.format("1809 8001 0330 %w 0030 8805 0030 %w 00 ff00 00000000", [0x8802, 0x8806])

    playback_reply =
      Query.format("1809 8001 0330 8802 0030 8805 0030 8806 00 1000 00090000 %x 00", [
        # Bytes 4 and 5 encode the operating status: 0xC375 is playing.
        <<0, 0, 0, 0, 0xC3, 0x75>>
      ])

    position_command =
      Query.format("1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 ff00 00000000")

    position_reply =
      Query.format(
        "1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 1000 00090000 " <>
          "000b 0002 0007 00 %w %B %B %B %B",
        [3, 0, 2, 30, 15]
      )

    script =
      descriptor("80 00", "01") ++
        exchange(status_command, status_reply) ++
        descriptor("80 00", "00") ++
        descriptor("80 00", "01") ++
        exchange(playback_command, playback_reply) ++
        descriptor("80 00", "00") ++
        descriptor("80 00", "01") ++
        exchange(position_command, position_reply) ++
        descriptor("80 00", "00")

    {:ok, pid} = MockTransport.start_script([@clean_poll | script])
    {:ok, device} = Device.open(transport: MockTransport, script: pid)

    assert {:ok, status} = Commands.device_status(device)

    assert status == %{
             disc_present: true,
             state: :playing,
             track: 3,
             time: %{minute: 2, second: 30, frame: 15}
           }

    assert MockTransport.remaining(pid) == []
  end

  test "time_to_frames" do
    assert Commands.time_to_frames({0, 0, 1, 0}) == 512
    assert Commands.time_to_frames({0, 1, 0, 0}) == 30_720
    assert Commands.time_to_frames({1, 2, 3, 4}) == (3600 + 120 + 3) * 512 + 4
  end

  describe "audio headers" do
    vectors =
      "../fixtures/header_vectors.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> JSON.decode!()

    @aea_vectors vectors["aea"]
    @wav_vectors vectors["wav"]

    test "AEA headers match the reference" do
      for %{
            "name" => name,
            "channels" => channels,
            "soundgroups" => soundgroups,
            "header" => header
          } <- @aea_vectors do
        assert Audio.aea_header(name, channels, soundgroups) ==
                 Base.decode16!(header, case: :lower),
               "aea header for #{inspect(name)}"
      end
    end

    test "WAV headers match the reference" do
      for %{"format" => format, "bytes" => bytes, "header" => header} <- @wav_vectors do
        assert Audio.wav_header(format, bytes) == Base.decode16!(header, case: :lower)
      end
    end
  end

  describe "compile_disc_titles/1" do
    test "plain title without groups" do
      disc = %Disc{title: "My Disc", full_width_title: ""}
      assert Commands.compile_disc_titles(disc) == {"My Disc", ""}
    end

    test "title and groups become raw markup" do
      tracks_a =
        for index <- 0..2 do
          %Disc.Track{index: index, title: "T#{index}", duration: 0, encoding: :sp}
        end

      tracks_b = [%Disc.Track{index: 3, title: "T3", duration: 0, encoding: :sp}]

      disc = %Disc{
        title: "Mix",
        full_width_title: "",
        track_count: 4,
        groups: [
          %Disc.Group{index: 0, title: "Rock", tracks: tracks_a},
          %Disc.Group{index: 1, title: "Solo", tracks: tracks_b}
        ]
      }

      assert Commands.compile_disc_titles(disc) == {"0;Mix//1-3;Rock//4;Solo//", ""}
    end

    test "full-width titles are compiled when present" do
      disc = %Disc{
        title: "Mix",
        full_width_title: "ミックス",
        track_count: 1,
        groups: [
          %Disc.Group{
            index: 0,
            title: "G",
            full_width_title: "グループ",
            tracks: [%Disc.Track{index: 0, title: "T", duration: 0, encoding: :sp}]
          }
        ]
      }

      assert {"0;Mix//1;G//", "０；ミックス／／１；グループ／／"} =
               Commands.compile_disc_titles(disc)
    end
  end

  test "cells_for_title accounts for the LP prefix" do
    sp_track = %Disc.Track{index: 0, title: "", duration: 0, encoding: :sp}
    lp_track = %Disc.Track{index: 1, title: "", duration: 0, encoding: :lp2}

    assert Commands.cells_for_title(sp_track) == {0, 0}
    assert Commands.cells_for_title(lp_track) == {1, 1}
  end
end
