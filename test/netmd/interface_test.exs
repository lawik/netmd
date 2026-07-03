defmodule Netmd.InterfaceTest do
  use ExUnit.Case, async: true

  alias Netmd.Device
  alias Netmd.Interface
  alias Netmd.MockTransport
  alias Netmd.Query

  @clean_poll {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}

  defp open!(script) do
    {:ok, pid} = MockTransport.start_script([@clean_poll | script])
    {:ok, device} = Device.open(transport: MockTransport, script: pid)
    {device, pid}
  end

  defp assert_done(pid), do: assert(MockTransport.remaining(pid) == [])

  # One command/reply exchange as seen on the wire. Both arguments are
  # payloads without the status byte.
  defp exchange(command, reply, reply_status \\ 0x09) do
    length = byte_size(reply) + 1

    [
      {{:control_out, 0x80, <<0x00>> <> command}, :ok},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, length, 0>>}},
      {{:control_in, 0x81, length}, {:ok, <<reply_status>> <> reply}},
      @clean_poll
    ]
  end

  # Descriptor open/close exchanges wrap most information commands.
  defp descriptor(descriptor_hex, action_hex) do
    command = Query.format("1808 #{descriptor_hex} #{action_hex} 00")
    exchange(command, command)
  end

  describe "playback control" do
    test "play sends the byte sequence libnetmd documents" do
      command = <<0x18, 0xC3, 0xFF, 0x75, 0x00, 0x00, 0x00>>
      {device, pid} = open!(exchange(command, <<0x18, 0xC3, 0x00, 0x75, 0x00, 0x00, 0x00>>))

      assert :ok = Interface.play(device)
      assert_done(pid)
    end

    test "pause, fast-forward and rewind use their action bytes" do
      for {fun, action} <- [pause: 0x7D, fast_forward: 0x39, rewind: 0x49] do
        command = <<0x18, 0xC3, 0xFF, action, 0x00, 0x00, 0x00>>
        {device, pid} = open!(exchange(command, <<0x18, 0xC3, 0x00, action, 0x00, 0x00, 0x00>>))

        assert :ok = apply(Interface, fun, [device])
        assert_done(pid)
      end
    end

    test "stop swallows rejections like the reference" do
      command = Query.format("18c5 ff 00000000")
      {device, pid} = open!(exchange(command, command, 0x0A))

      assert :ok = Interface.stop(device)
      assert_done(pid)
    end

    test "goto_track confirms the seek" do
      command = Query.format("1850 ff010000 0000 %w", [3])
      reply = Query.format("1850 00010000 0000 %w", [3])
      {device, pid} = open!(exchange(command, reply))

      assert {:ok, 3} = Interface.goto_track(device, 3)
      assert_done(pid)
    end
  end

  describe "reply status handling" do
    test "rejected replies become error tuples" do
      command = Query.format("1840 ff 0000")
      {device, pid} = open!(exchange(command, command, 0x0A))

      assert {:error, {:rejected, _}} = Interface.erase_disc(device)
      assert_done(pid)
    end

    test "not implemented replies become error tuples" do
      command = Query.format("1840 ff 0000")
      {device, pid} = open!(exchange(command, command, 0x08))

      assert {:error, :not_implemented} = Interface.erase_disc(device)
      assert_done(pid)
    end

    test "interim replies are retried until the real one arrives" do
      command = Query.format("1840 ff 0000")
      reply = Query.format("1840 00 0000")
      length = byte_size(reply) + 1

      script = [
        {{:control_out, 0x80, <<0x00>> <> command}, :ok},
        {{:control_in, 0x01, 4}, {:ok, <<0, 0, length, 0>>}},
        {{:control_in, 0x81, length}, {:ok, <<0x0F>> <> reply}},
        @clean_poll,
        # retry reads again without resending
        {{:control_in, 0x01, 4}, {:ok, <<0, 0, length, 0>>}},
        {{:control_in, 0x81, length}, {:ok, <<0x09>> <> reply}},
        @clean_poll
      ]

      {device, pid} = open!(script)
      assert :ok = Interface.erase_disc(device)
      assert_done(pid)
    end
  end

  describe "disc information" do
    test "track_count unwraps the descriptor dance" do
      command = Query.format("1806 02101001 3000 1000 ff00 00000000")
      reply = Query.format("1806 02101001 3000 1000 1000 00000000 0006 0010000200 %b", [7])

      script =
        descriptor("10 1001", "01") ++
          exchange(command, reply) ++
          descriptor("10 1001", "00")

      {device, pid} = open!(script)
      assert {:ok, 7} = Interface.track_count(device)
      assert_done(pid)
    end

    test "disc_flags reads the root descriptor" do
      command = Query.format("1806 01101000 ff00 0001000b")
      reply = Query.format("1806 01101000 1000 0001000b %b", [0x10])

      script =
        descriptor("10 1000", "01") ++ exchange(command, reply) ++ descriptor("10 1000", "00")

      {device, pid} = open!(script)
      assert {:ok, 0x10} = Interface.disc_flags(device)
      assert_done(pid)
    end

    test "disc_present? inspects byte four of the status block" do
      for {byte, expected} <- [{0x40, true}, {0x80, false}] do
        command = Query.format("1809 8001 0230 8800 0030 8804 00 ff00 00000000")

        reply =
          Query.format("1809 8001 0230 8800 0030 8804 00 1000 00090000 %x", [
            <<0x00, 0x00, 0x00, 0x00, byte, 0x00, 0x00, 0x00>>
          ])

        script =
          descriptor("80 00", "01") ++ exchange(command, reply) ++ descriptor("80 00", "00")

        {device, pid} = open!(script)
        assert {:ok, ^expected} = Interface.disc_present?(device)
        assert_done(pid)
      end
    end

    test "position parses track and BCD time" do
      command = Query.format("1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 ff00 00000000")

      reply =
        Query.format(
          "1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 1000 00090000 " <>
            "000b 0002 0007 00 %w %B %B %B %B",
          [2, 0, 1, 23, 45]
        )

      script = descriptor("80 00", "01") ++ exchange(command, reply) ++ descriptor("80 00", "00")

      {device, pid} = open!(script)
      assert {:ok, %{track: 2, time: {0, 1, 23, 45}}} = Interface.position(device)
      assert_done(pid)
    end

    test "position is nil when the device rejects the query" do
      command = Query.format("1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 ff00 00000000")

      script =
        descriptor("80 00", "01") ++ exchange(command, command, 0x0A) ++ descriptor("80 00", "00")

      {device, pid} = open!(script)
      assert {:ok, nil} = Interface.position(device)
      assert_done(pid)
    end

    test "disc_capacity parses three BCD durations" do
      command = Query.format("1806 02101000 3080 0300 ff00 00000000")

      reply =
        Query.format(
          "1806 02101000 3080 0300 1000 001d0000 001b 8003 0017 8000 " <>
            "0005 %W %B %B %B 0005 %W %B %B %B 0005 %W %B %B %B",
          [0, 50, 12, 34, 1, 20, 59, 0, 0, 30, 47, 12]
        )

      script =
        descriptor("10 1000", "01") ++ exchange(command, reply) ++ descriptor("10 1000", "00")

      {device, pid} = open!(script)

      assert {:ok, [{0, 50, 12, 34}, {1, 20, 59, 0}, {0, 30, 47, 12}]} =
               Interface.disc_capacity(device)

      assert_done(pid)
    end
  end

  describe "titles" do
    test "raw_disc_title reads a single chunk" do
      command = Query.format("1806 02201801 00%b 3000 0a00 ff00 %w%w", [0, 0, 0])

      reply =
        Query.format("1806 02201801 0000 3000 0a00 1000 %w 0000 0000 000a %w %*", [
          11,
          5,
          "Hello"
        ])

      script =
        descriptor("10 1001", "01") ++
          descriptor("10 1801", "01") ++
          exchange(command, reply) ++
          descriptor("10 1801", "00") ++
          descriptor("10 1001", "00")

      {device, pid} = open!(script)
      assert {:ok, "Hello"} = Interface.raw_disc_title(device)
      assert_done(pid)
    end

    test "raw_disc_title stitches chunked replies" do
      first_command = Query.format("1806 02201801 00%b 3000 0a00 ff00 %w%w", [0, 0, 0])

      first_reply =
        Query.format("1806 02201801 0000 3000 0a00 1000 %w 0000 0000 000a %w %*", [
          11,
          10,
          "Hello"
        ])

      second_command = Query.format("1806 02201801 00%b 3000 0a00 ff00 %w%w", [0, 5, 5])

      second_reply =
        Query.format("1806 02201801 0000 3000 0a00 1000 %w 0000 %*", [5, "World"])

      script =
        descriptor("10 1001", "01") ++
          descriptor("10 1801", "01") ++
          exchange(first_command, first_reply) ++
          exchange(second_command, second_reply) ++
          descriptor("10 1801", "00") ++
          descriptor("10 1001", "00")

      {device, pid} = open!(script)
      assert {:ok, "HelloWorld"} = Interface.raw_disc_title(device)
      assert_done(pid)
    end

    test "disc_title strips group markup" do
      reply =
        Query.format("1806 02201801 0000 3000 0a00 1000 %w 0000 0000 000a %w %*", [
          24,
          18,
          "0;My Disc//1-2;Xy//"
        ])

      # 18 characters of title means one chunk read
      command = Query.format("1806 02201801 00%b 3000 0a00 ff00 %w%w", [0, 0, 0])

      script =
        descriptor("10 1001", "01") ++
          descriptor("10 1801", "01") ++
          exchange(command, reply) ++
          descriptor("10 1801", "00") ++
          descriptor("10 1001", "00")

      {device, pid} = open!(script)
      assert {:ok, "My Disc"} = Interface.disc_title(device)
      assert_done(pid)
    end

    test "track_title decodes SJIS" do
      command = Query.format("1806 022018%b %w 3000 0a00 ff00 00000000", [2, 1])

      reply =
        Query.format("1806 022018 02 %w 3000 0a00 1000 00000000 0000000a %x", [1, "My Track"])

      script =
        descriptor("10 1802", "01") ++ exchange(command, reply) ++ descriptor("10 1802", "00")

      {device, pid} = open!(script)
      assert {:ok, "My Track"} = Interface.track_title(device, 1)
      assert_done(pid)
    end

    test "set_track_title fetches the old title and writes the new one" do
      read_command = Query.format("1806 022018%b %w 3000 0a00 ff00 00000000", [2, 0])

      read_reply =
        Query.format("1806 022018 02 %w 3000 0a00 1000 00000000 0000000a %x", [0, "Old"])

      write_command =
        Query.format("1807 022018%b %w 3000 0a00 5000 %w 0000 %w %*", [2, 0, 3, 3, "New"])

      write_reply = Query.format("1807 022018 02 %w 3000 0a00 5000 0003 0000 0003", [0])

      script =
        descriptor("10 1802", "01") ++
          exchange(read_command, read_reply) ++
          descriptor("10 1802", "00") ++
          descriptor("10 1802", "03") ++
          exchange(write_command, write_reply) ++
          descriptor("10 1802", "00")

      {device, pid} = open!(script)
      assert :ok = Interface.set_track_title(device, 0, "New")
      assert_done(pid)
    end
  end

  describe "track information" do
    test "track_encoding returns codec and channel bytes" do
      command = Query.format("1806 02201001 %w %w %w ff00 00000000", [0, 0x3080, 0x0700])

      reply =
        Query.format("1806 02201001 %w 3080 0700 1000 00000000 %x", [
          0,
          Query.format("8007 0004 0110 %b %b", [0x92, 0x00])
        ])

      script =
        descriptor("10 1001", "01") ++ exchange(command, reply) ++ descriptor("10 1001", "00")

      {device, pid} = open!(script)
      assert {:ok, {0x92, 0x00}} = Interface.track_encoding(device, 0)
      assert_done(pid)
    end

    test "track_length returns a BCD time tuple" do
      command = Query.format("1806 02201001 %w %w %w ff00 00000000", [2, 0x3000, 0x0100])

      reply =
        Query.format("1806 02201001 %w 3000 0100 1000 00000000 %x", [
          2,
          Query.format("0001 0006 0000 %B %B %B %B", [0, 4, 20, 12])
        ])

      script =
        descriptor("10 1001", "01") ++ exchange(command, reply) ++ descriptor("10 1001", "00")

      {device, pid} = open!(script)
      assert {:ok, {0, 4, 20, 12}} = Interface.track_length(device, 2)
      assert_done(pid)
    end
  end

  describe "session" do
    test "acquire and release" do
      acquire_query = Query.format("ff 010c ffff ffff ffff ffff ffff ffff")
      release_query = Query.format("ff 0100 ffff ffff ffff ffff ffff ffff")

      script = exchange(acquire_query, acquire_query) ++ exchange(release_query, release_query)

      {device, pid} = open!(script)
      assert :ok = Interface.acquire(device)
      assert :ok = Interface.release(device)
      assert_done(pid)
    end
  end
end
