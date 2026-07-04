defmodule NetMD.SessionTest do
  use ExUnit.Case, async: true

  alias NetMD.Crypto
  alias NetMD.Device
  alias NetMD.EKB
  alias NetMD.MockTransport
  alias NetMD.Query
  alias NetMD.Session
  alias NetMD.Track

  @zero_iv <<0::64>>
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

  test "full download session against a scripted device" do
    host_nonce = <<0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17>>
    device_nonce = <<0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7>>
    leaf_id = <<0, 1, 2, 3, 4, 5, 6, 7>>
    raw_key = <<9, 9, 9, 9, 9, 9, 9, 9>>
    data = :binary.copy(<<0xCD>>, 96)

    ekb = EKB.open_source()
    session_key = Crypto.retailmac(ekb.root_key, host_nonce <> device_nonce)

    track = %Track{title: "Test", format: :lp4, data: data, raw_key: raw_key}

    packet_key = Crypto.des_ecb_decrypt(Track.kek(), raw_key)
    encrypted_data = Crypto.des_cbc_encrypt(raw_key, @zero_iv, data)
    binpack = <<0, 0, 0, 0, 96::little-32>> <> packet_key <> @zero_iv <> encrypted_data

    setup_message =
      Crypto.des_cbc_encrypt(
        session_key,
        @zero_iv,
        <<1, 1, 1, 1>> <> Track.content_id() <> Track.kek()
      )

    confirmation =
      Crypto.des_cbc_encrypt(
        session_key,
        @zero_iv,
        "UUIDUUID" <> <<0, 0, 0, 0>> <> "CCID-678901234567890"
      )

    key_data_command =
      Query.format("1800 080046 f0030103 12 ff %w 0000 %w %d %d %d 00000000 %* %*", [
        72,
        72,
        2,
        ekb.depth,
        ekb.id,
        IO.iodata_to_binary(ekb.chain),
        ekb.signature
      ])

    send_track_command =
      Query.format("1800 080046 f0030103 28 ff 000100 1001 ffff 00 %b %b %d %d", [
        0xA8,
        0x00,
        1,
        120
      ])

    final_reply =
      Query.format("1800 080046 f0030103 28 00 000100 1001 %w 00 0000 00000000 00000000 %*", [
        0,
        confirmation
      ])

    final_length = byte_size(final_reply) + 1

    # Session.start
    # download_track: setup, announce, packets, confirmation
    # set_track_title: read current (rejected: brand new track), write
    # commit
    # Session.close: forget key, leave secure session
    script =
      exchange(
        Query.format("1800 080046 f0030103 80 ff"),
        Query.format("1800 080046 f0030103 80 00")
      ) ++
        exchange(
          Query.format("1800 080046 f0030103 11 ff"),
          Query.format("1800 080046 f0030103 11 00 %*", [leaf_id])
        ) ++
        exchange(
          key_data_command,
          Query.format("1800 080046 f0030103 12 01 0000 00000000")
        ) ++
        exchange(
          Query.format("1800 080046 f0030103 20 ff 000000 %*", [host_nonce]),
          Query.format("1800 080046 f0030103 20 00 000000 %*", [device_nonce])
        ) ++
        exchange(
          Query.format("1800 080046 f0030103 22 ff 0000 %*", [setup_message]),
          Query.format("1800 080046 f0030103 22 00 0000")
        ) ++
        exchange(
          send_track_command,
          Query.format("1800 080046 f0030103 28 00 000100 1001 0000 00")
        ) ++
        [
          {{:bulk_out, binpack}, :ok},
          {{:control_in, 0x01, 4}, {:ok, <<0, 0, final_length, 0>>}},
          {{:control_in, 0x81, final_length}, {:ok, <<0x09>> <> final_reply}},
          @clean_poll,
          # send_track polls the reply length once more, like the reference
          @clean_poll
        ] ++
        descriptor("10 1802", "01") ++
        exchange(
          Query.format("1806 022018%b %w 3000 0a00 ff00 00000000", [2, 0]),
          Query.format("1806 022018%b %w 3000 0a00 ff00 00000000", [2, 0]),
          0x0A
        ) ++
        descriptor("10 1802", "00") ++
        descriptor("10 1802", "03") ++
        exchange(
          Query.format("1807 022018%b %w 3000 0a00 5000 %w 0000 %w %*", [2, 0, 4, 0, "Test"]),
          Query.format("1807 022018%b %w 3000 0a00 5000 %w 0000 %w", [2, 0, 4, 0])
        ) ++
        descriptor("10 1802", "00") ++
        exchange(
          Query.format("1800 080046 f0030103 48 ff 00 1001 %w %*", [
            0,
            Crypto.des_ecb_encrypt(session_key, @zero_iv)
          ]),
          Query.format("1800 080046 f0030103 48 00 00 1001 0000")
        ) ++
        exchange(
          Query.format("1800 080046 f0030103 21 ff 000000"),
          Query.format("1800 080046 f0030103 21 00 000000")
        ) ++
        exchange(
          Query.format("1800 080046 f0030103 81 ff"),
          Query.format("1800 080046 f0030103 81 00")
        )

    {:ok, pid} = MockTransport.start_script([@clean_poll | script])
    {:ok, device} = Device.open(transport: MockTransport, script: pid)

    assert {:ok, session} = Session.start(device, host_nonce: host_nonce)
    assert session.key == session_key

    assert {:ok, %{track: 0, uuid: "UUIDUUID", ccid: "CCID-678901234567890"}} =
             Session.download_track(session, track, settle_ms: 0)

    assert :ok = Session.close(session)
    assert MockTransport.remaining(pid) == []
  end

  test "corrupted deck EKB is selected for all-ff leaf ids on the Sony decks" do
    assert %EKB{id: 0x13371337} = EKB.for_device(:binary.copy(<<0xFF>>, 8), 0x054C, 0x0081)
    assert %EKB{id: 0x26422642} = EKB.for_device(:binary.copy(<<0xFF>>, 8), 0x054C, 0x00C8)
    assert %EKB{id: 0x26422642} = EKB.for_device(<<0, 1, 2, 3, 4, 5, 6, 7>>, 0x054C, 0x0081)
  end
end
