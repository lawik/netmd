defmodule NetMD.FactoryTest do
  use ExUnit.Case, async: true

  alias NetMD.Crypto
  alias NetMD.Device
  alias NetMD.Factory
  alias NetMD.Factory.Commands
  alias NetMD.MockTransport
  alias NetMD.Query

  @clean_poll {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}

  # A factory exchange: command out on request 0xff, reply read on 0xff.
  defp exchange(command, reply, reply_status \\ 0x09) do
    length = byte_size(reply) + 1

    [
      {{:control_out, 0xFF, <<0x00>> <> command}, :ok},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, length, 0>>}},
      {{:control_in, 0xFF, length}, {:ok, <<reply_status>> <> reply}},
      @clean_poll
    ]
  end

  # A normal (non-factory) exchange on requests 0x80 / 0x81.
  defp exchange_std(command, reply, reply_status \\ 0x09) do
    length = byte_size(reply) + 1

    [
      {{:control_out, 0x80, <<0x00>> <> command}, :ok},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, length, 0>>}},
      {{:control_in, 0x81, length}, {:ok, <<reply_status>> <> reply}},
      @clean_poll
    ]
  end

  # Both entry points run the subunit-identifier handshake first; its
  # result is ignored, so a rejection is fine.
  defp subunit_handshake do
    exchange_std(Query.format("1808 00 01 00"), <<0x18, 0x08>>) ++
      exchange_std(Query.format("1809 00 ff00 0000 0000"), Query.format("1809 00"), 0x0A) ++
      exchange_std(Query.format("1808 00 00 00"), <<0x18, 0x08>>)
  end

  defp open_factory!(variant, script) do
    {:ok, pid} = MockTransport.start_script([@clean_poll | script])
    {:ok, device} = Device.open(transport: MockTransport, script: pid)
    {%Factory{device: device, variant: variant}, pid}
  end

  defp assert_done(pid), do: assert(MockTransport.remaining(pid) == [])

  describe "pure functions against reference vectors" do
    vectors =
      "../fixtures/factory_vectors.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> JSON.decode!()

    @checksum8 vectors["checksum8"]
    @checksum8_seed vectors["checksum8_seed"]
    @eeprom vectors["eeprom_checksum"]
    @transfer vectors["transfer_crypto"]
    @device_codes vectors["device_codes"]

    defp unhex(hex), do: Base.decode16!(hex, case: :lower)

    test "8-bit checksum matches" do
      for %{"data" => data, "checksum" => expected} <- @checksum8 do
        assert Factory.checksum(unhex(data)) == expected, "checksum of #{data}"
      end
    end

    test "8-bit checksum with seed matches" do
      for %{"data" => data, "seed" => seed, "checksum" => expected} <- @checksum8_seed do
        assert Factory.checksum(unhex(data), seed: seed) == expected
      end
    end

    test "EEPROM (16-bit) checksum matches for both seeds" do
      for %{"data" => data, "himd_checksum" => himd, "netmd_checksum" => netmd} <- @eeprom do
        assert Factory.eeprom_checksum(unhex(data), himd: true) == himd
        assert Factory.eeprom_checksum(unhex(data), himd: false) == netmd
      end
    end

    test "factory transfer crypto matches and round-trips" do
      for %{"plaintext" => plaintext, "encrypted" => encrypted, "roundtrip" => roundtrip} <-
            @transfer do
        assert Crypto.factory_transfer_encrypt(unhex(plaintext)) == unhex(encrypted)
        assert Crypto.factory_transfer_decrypt(unhex(encrypted)) == unhex(roundtrip)
      end
    end

    test "descriptive device codes match" do
      for %{
            "chipType" => chip,
            "version" => version,
            "subversion" => subversion,
            "code" => code
          } <- @device_codes do
        assert Factory.descriptive_code(chip, version, subversion) == code
      end
    end
  end

  describe "open/1 entry point" do
    test "a plain NetMD device authenticates as :netmd" do
      auth = Query.format("1801 ff0e 4e6574204d442057616c6b6d616e")
      code_reply = Query.format("1812 00 %b %b %b %B", [0x21, 0x00, 0x00, 21])

      script =
        subunit_handshake() ++
          exchange(auth, <<0x18, 0x01>>) ++
          exchange(Query.format("1812 ff"), code_reply)

      {:ok, pid} = MockTransport.start_script([@clean_poll | script])

      {:ok, device} =
        Device.open(transport: MockTransport, script: pid, vendor_id: 0x054C, product_id: 0x00C8)

      assert {:ok, %Factory{variant: :netmd}} = Factory.open(device)
      assert_done(pid)
    end

    test "an MZ-RH1 is promoted to the :rh1 variant by its device code" do
      auth = Query.format("1802 ff04 4d44574d")
      # chip 0x25 -> "Hx..." triggers the RH1 promotion
      code_reply = Query.format("1812 00 %b %b %b %B", [0x25, 0x00, 0x03, 12])

      script =
        subunit_handshake() ++
          exchange(auth, <<0x18, 0x02>>) ++
          exchange(Query.format("1812 ff"), code_reply)

      {:ok, pid} = MockTransport.start_script([@clean_poll | script])

      {:ok, device} =
        Device.open(transport: MockTransport, script: pid, vendor_id: 0x054C, product_id: 0x0286)

      assert {:ok, %Factory{variant: :rh1}} = Factory.open(device)
      assert_done(pid)
    end
  end

  describe "auth" do
    test "netmd sends the Walkman string" do
      command = Query.format("1801 ff0e 4e6574204d442057616c6b6d616e")
      {factory, pid} = open_factory!(:netmd, exchange(command, <<0x18, 0x01>>))
      assert :ok = Factory.auth(factory)
      assert_done(pid)
    end

    test "himd sends the MDWM string" do
      command = Query.format("1802 ff04 4d44574d")
      {factory, pid} = open_factory!(:himd, exchange(command, <<0x18, 0x02>>))
      assert :ok = Factory.auth(factory)
      assert_done(pid)
    end
  end

  describe "memory read" do
    test "netmd read strips the trailing checksum" do
      command = Query.format("1821 ff %b %<d %b", [0x0, 0x1000, 4])
      # reply payload: header + data (4 bytes) + 2-byte checksum
      payload = <<0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34>>
      reply = Query.format("1821 00 00 %<d 00 0000 %*", [0x1000, payload])

      {factory, pid} = open_factory!(:netmd, exchange(command, reply))
      assert {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>} = Factory.read(factory, 0x1000, 4, :mapped)
      assert_done(pid)
    end

    test "himd packs length and type into the header byte" do
      # length 4, type mapped(0) => head 4; type eeprom_2(2) => head 0x44
      command = Query.format("182c ff %b %<d", [0x44, 0x2000])
      payload = <<1, 2, 3, 4, 0xAA, 0xBB>>
      reply = Query.format("182c 00 00 %<d 00 0000 %*", [0x2000, payload])

      {factory, pid} = open_factory!(:himd, exchange(command, reply))
      assert {:ok, <<1, 2, 3, 4>>} = Factory.read(factory, 0x2000, 4, :eeprom_2)
      assert_done(pid)
    end

    test "himd rejects transfers over 0x1f bytes" do
      {factory, _pid} = open_factory!(:himd, [])
      assert {:error, {:transfer_too_long, 32}} = Factory.read(factory, 0x2000, 32, :mapped)
    end
  end

  describe "memory write" do
    test "netmd write appends the checksum" do
      data = <<0xCA, 0xFE>>
      crc = Factory.checksum(data)
      command = Query.format("1822 ff %b %<d %b 0000 %* %<w", [0x0, 0x1000, 2, data, crc])
      {factory, pid} = open_factory!(:netmd, exchange(command, <<0x18, 0x22>>))

      assert :ok = Factory.write(factory, 0x1000, data, :mapped)
      assert_done(pid)
    end

    test "himd write uses the 0xA596 seed and packed header" do
      data = <<0xCA, 0xFE>>
      crc = Factory.checksum(data, seed: 0xA596)
      command = Query.format("182d ff %b %<d %b 0000 %* %<w", [0x2, 0x1000, 2, data, crc])
      {factory, pid} = open_factory!(:himd, exchange(command, <<0x18, 0x2D>>))

      assert :ok = Factory.write(factory, 0x1000, data, :mapped)
      assert_done(pid)
    end
  end

  describe "device info" do
    test "device_code parses the fields and versions" do
      command = Query.format("1812 ff")
      reply = Query.format("1812 00 %b %b %b %B", [0x21, 0x05, 0x12, 25])
      {factory, pid} = open_factory!(:netmd, exchange(command, reply))

      assert {:ok, %{chip_type: 0x21, hwid: 0x05, subversion: 0x12, version: 25}} =
               Factory.device_code(factory)

      assert_done(pid)
    end

    test "descriptive_device_code composes chip and version" do
      command = Query.format("1812 ff")
      reply = Query.format("1812 00 %b %b %b %B", [0x21, 0x05, 0x12, 25])
      {factory, pid} = open_factory!(:netmd, exchange(command, reply))

      assert {:ok, "S2.512"} = Factory.descriptive_device_code(factory)
      assert_done(pid)
    end

    test "device_version reads the BCD firmware version" do
      command = Query.format("1813 ff")
      reply = Query.format("1813 00 00 %B", [21])
      {factory, pid} = open_factory!(:netmd, exchange(command, reply))

      assert {:ok, 21} = Factory.device_version(factory)
      assert_done(pid)
    end
  end

  describe "RH1 DRAM addressing" do
    test "read translates a mapped DRAM address to a peripheral read" do
      address = 0x02000000 + 2368 * 3 + 100
      command = Query.format("1824 ff %<w %<w %b", [3, 100, 16])
      reply = Query.format("1824 00 00000000 %b %*", [16, :binary.copy(<<0x55>>, 16)])

      {factory, pid} = open_factory!(:rh1, exchange(command, reply))
      assert {:ok, data} = Factory.read(factory, address, 16, :mapped)
      assert data == :binary.copy(<<0x55>>, 16)
      assert_done(pid)
    end

    test "rejects addresses below the DRAM base" do
      {factory, _pid} = open_factory!(:rh1, [])
      assert {:error, {:invalid_rh1_address, _}} = Factory.read(factory, 0x1000, 16, :mapped)
    end

    test "change_memory_state is a no-op" do
      {factory, pid} = open_factory!(:rh1, [])
      assert :ok = Factory.change_memory_state(factory, 0x02000000, 16, :mapped, :read)
      assert_done(pid)
    end
  end

  describe "display override" do
    test "encodes text to SJIS and pads to ten bytes" do
      padded = "Hi" <> :binary.copy(<<0>>, 8)
      command = Query.format("1852 ff %b %b 00 %*", [0, 0, padded])
      {factory, pid} = open_factory!(:netmd, exchange(command, <<0x18, 0x52>>))

      assert :ok = Factory.set_display_override(factory, "Hi")
      assert_done(pid)
    end

    test "rejects text longer than nine bytes" do
      {factory, _pid} = open_factory!(:netmd, [])

      assert_raise ArgumentError, fn ->
        Factory.set_display_override(factory, "0123456789")
      end
    end
  end

  describe "clean_read/clean_write bracketing" do
    test "clean_read opens, reads and closes" do
      open = Query.format("1820 ff %b %<d %b %b %b", [0x0, 0x1000, 4, 0x1, 0])
      read = Query.format("1821 ff %b %<d %b", [0x0, 0x1000, 4])
      close = Query.format("1820 ff %b %<d %b %b %b", [0x0, 0x1000, 4, 0x0, 0])

      payload = <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00>>
      read_reply = Query.format("1821 00 00 %<d 00 0000 %*", [0x1000, payload])

      script =
        exchange(open, <<0x18, 0x20>>) ++
          exchange(read, read_reply) ++
          exchange(close, <<0x18, 0x20>>)

      {factory, pid} = open_factory!(:netmd, script)
      assert {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>} = Commands.clean_read(factory, 0x1000, 4, :mapped)
      assert_done(pid)
    end

    test "clean_write with encryption encrypts before writing" do
      plaintext = <<1, 2, 3, 4, 5, 6, 7, 8>>
      ciphertext = Crypto.factory_transfer_encrypt(plaintext)
      length = byte_size(ciphertext)
      crc = Factory.checksum(ciphertext)

      open = Query.format("1820 ff %b %<d %b %b %b", [0x0, 0x1000, length, 0x2, 1])

      write =
        Query.format("1822 ff %b %<d %b 0000 %* %<w", [0x0, 0x1000, length, ciphertext, crc])

      close = Query.format("1820 ff %b %<d %b %b %b", [0x0, 0x1000, length, 0x0, 1])

      script =
        exchange(open, <<0x18, 0x20>>) ++
          exchange(write, <<0x18, 0x22>>) ++
          exchange(close, <<0x18, 0x20>>)

      {factory, pid} = open_factory!(:netmd, script)
      assert :ok = Commands.clean_write(factory, 0x1000, plaintext, :mapped, encrypted: true)
      assert_done(pid)
    end
  end

  describe "UTOC sectors" do
    test "read_utoc_sector concatenates 147 peripheral reads" do
      script =
        Enum.flat_map(0..146, fn i ->
          command = Query.format("1824 ff %<w %<w %b", [0, i * 0x10, 0x10])
          reply = Query.format("1824 00 00000000 %b %*", [0x10, :binary.copy(<<i>>, 16)])
          exchange(command, reply)
        end)

      {factory, pid} = open_factory!(:netmd, script)
      assert {:ok, data} = Commands.read_utoc_sector(factory, 0)
      assert byte_size(data) == 2352
      assert binary_part(data, 0, 16) == :binary.copy(<<0>>, 16)
      assert binary_part(data, 16, 16) == :binary.copy(<<1>>, 16)
      assert_done(pid)
    end

    test "write_utoc_sector rejects wrong-sized data" do
      {factory, _pid} = open_factory!(:netmd, [])

      assert_raise FunctionClauseError, fn ->
        Commands.write_utoc_sector(factory, 0, <<0, 1, 2>>)
      end
    end
  end
end
