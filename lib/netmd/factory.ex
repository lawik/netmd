defmodule NetMD.Factory do
  @moduledoc """
  The NetMD factory command set, ported from netmd-js.

  Factory mode exposes the player's internal memory (RAM / EEPROM / disc
  cache peripheral) for reading and writing. It backs firmware patching,
  raw UTOC access and the display override. **This is dangerous; a wrong
  write can brick the device.** Do not use it unless you know exactly what
  you are doing.

  Three device families need slightly different framing, modelled as a
  tagged struct (`:netmd`, `:himd`, `:rh1`). Open one with `open/1`, which
  authenticates and detects the variant, then use the memory and device
  functions here or the higher-level operations in `NetMD.Factory.Commands`.
  """

  import Bitwise, only: [band: 2, bor: 2, bxor: 2, bsl: 2]

  alias NetMD.Device
  alias NetMD.Interface
  alias NetMD.Query
  alias NetMD.SJIS

  @enforce_keys [:device, :variant]
  defstruct [:device, :variant]

  @typedoc "Device family: base NetMD, Hi-MD, or the MZ-RH1 special case."
  @type variant :: :netmd | :himd | :rh1

  @typedoc "An authenticated factory interface."
  @type t :: %__MODULE__{device: Device.t(), variant: variant()}

  @typedoc "Memory region to address."
  @type memory_type :: :mapped | :eeprom_2 | :eeprom_3 | 0..0xFF

  @typedoc "How to open a memory range."
  @type open_type :: :close | :read | :write | :read_write | 0..0xFF

  @type error :: Interface.error()

  @memory_types %{mapped: 0x0, eeprom_2: 0x2, eeprom_3: 0x3}
  @open_types %{close: 0x0, read: 0x1, write: 0x2, read_write: 0x3}
  @display_modes %{default: 0x0, override: 0x1}

  # HiMD read/write cap a transfer at 0x1F bytes.
  @himd_max_transfer 0x1F
  # RH1 maps DRAM through the metadata peripheral in these units.
  @rh1_dram_base 0x02000000
  @rh1_sub_block_size 2368

  @doc """
  Authenticate a factory session on an open device and detect its variant.

  Runs the same subunit-identifier handshake as the reference for side
  effects, authenticates, then reads the device code to promote MZ-RH1
  devices to their special interface.
  """
  @spec open(Device.t()) :: {:ok, t()} | error()
  def open(%Device{} = device) do
    # The reference reads the subunit identifier first; kept for parity.
    _ = Interface.netmd_level(device)

    himd? = String.contains?(Device.name(device), ["MZ-RH", "MZ-NH", "DS-HMD1"])
    factory = %__MODULE__{device: device, variant: if(himd?, do: :himd, else: :netmd)}

    with :ok <- auth(factory),
         {:ok, info} <- device_code(factory) do
      code = descriptive_code(info.chip_type, info.version, info.subversion)
      {:ok, if(String.starts_with?(code, "Hx"), do: %{factory | variant: :rh1}, else: factory)}
    end
  end

  @doc "Authenticate the factory session."
  @spec auth(t()) :: :ok | error()
  def auth(%__MODULE__{variant: :netmd} = factory) do
    # "Net MD Walkman"
    factory_send(factory, Query.format("1801 ff0e 4e6574204d442057616c6b6d616e"))
  end

  def auth(%__MODULE__{} = factory) do
    # "MDWM"
    factory_send(factory, Query.format("1802 ff04 4d44574d"))
  end

  @doc """
  Open, keep open, or close a memory range for access. A no-op on the
  MZ-RH1, which addresses memory through the peripheral instead.
  """
  @spec change_memory_state(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          memory_type(),
          open_type(),
          keyword()
        ) :: :ok | error()
  def change_memory_state(factory, address, length, type, state, opts \\ [])

  def change_memory_state(%__MODULE__{variant: :rh1}, _address, _length, _type, _state, _opts),
    do: :ok

  def change_memory_state(%__MODULE__{} = factory, address, length, type, state, opts) do
    command = if factory.variant == :himd, do: "182b", else: "1820"
    encrypted = if Keyword.get(opts, :encrypted, false), do: 1, else: 0

    query =
      Query.format("#{command} ff %b %<d %b %b %b", [
        memory_type(type),
        address,
        length,
        open_type(state),
        encrypted
      ])

    factory_send(factory, query)
  end

  @doc """
  Read `length` bytes of `type` memory at `address`.
  """
  @spec read(t(), non_neg_integer(), non_neg_integer(), memory_type()) ::
          {:ok, binary()} | error()
  def read(%__MODULE__{variant: :netmd} = factory, address, length, type) do
    query = Query.format("1821 ff %b %<d %b", [memory_type(type), address, length])

    with {:ok, reply} <- factory_query(factory, query),
         {:ok, [captured]} <- Query.scan(reply, "1821 00 %? %?%?%?%? %? %?%? %*") do
      {:ok, drop_checksum(captured)}
    end
  end

  def read(%__MODULE__{variant: :himd} = factory, address, length, type)
      when length <= @himd_max_transfer do
    query = Query.format("182c ff %b %<d", [transfer_head(length, type), address])

    with {:ok, reply} <- factory_query(factory, query),
         {:ok, [captured]} <- Query.scan(reply, "182c 00 %? %?%?%?%? %? %?%? %*") do
      {:ok, drop_checksum(captured)}
    end
  end

  def read(%__MODULE__{variant: :rh1} = factory, address, length, type) do
    with {:ok, sector, offset} <- rh1_address(address, type) do
      read_metadata_peripheral(factory, sector, offset, length)
    end
  end

  def read(%__MODULE__{variant: :himd}, _address, length, _type),
    do: {:error, {:transfer_too_long, length}}

  @doc """
  Write `data` to `type` memory at `address`.
  """
  @spec write(t(), non_neg_integer(), binary(), memory_type()) :: :ok | error()
  def write(%__MODULE__{variant: :netmd} = factory, address, data, type) do
    crc = checksum(data)

    query =
      Query.format("1822 ff %b %<d %b 0000 %* %<w", [
        memory_type(type),
        address,
        byte_size(data),
        data,
        crc
      ])

    factory_send(factory, query)
  end

  def write(%__MODULE__{variant: :himd} = factory, address, data, type)
      when byte_size(data) <= @himd_max_transfer do
    crc = checksum(data, seed: 0xA596)

    query =
      Query.format("182d ff %b %<d %b 0000 %* %<w", [
        transfer_head(byte_size(data), type),
        address,
        byte_size(data),
        data,
        crc
      ])

    factory_send(factory, query)
  end

  def write(%__MODULE__{variant: :rh1} = factory, address, data, type) do
    with {:ok, sector, offset} <- rh1_address(address, type) do
      write_metadata_peripheral(factory, sector, offset, data)
    end
  end

  def write(%__MODULE__{variant: :himd}, _address, data, _type),
    do: {:error, {:transfer_too_long, byte_size(data)}}

  @doc "Read `length` bytes from the disc-cache metadata peripheral."
  @spec read_metadata_peripheral(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | error()
  def read_metadata_peripheral(factory, sector, offset, length) do
    query = Query.format("1824 ff %<w %<w %b", [sector, offset, length])

    with {:ok, reply} <- factory_query(factory, query),
         {:ok, [_len, data]} <- Query.scan(reply, "1824 00 %?%?%?%? %b %*") do
      {:ok, data}
    end
  end

  @doc "Write to the disc-cache metadata peripheral."
  @spec write_metadata_peripheral(t(), non_neg_integer(), non_neg_integer(), binary()) ::
          :ok | error()
  def write_metadata_peripheral(factory, sector, offset, data) do
    factory_send(factory, Query.format("1825 ff %<w %<w %z", [sector, offset, data]))
  end

  @doc "Set the display mode (`:default` or `:override`)."
  @spec set_display_mode(t(), :default | :override) :: :ok | error()
  def set_display_mode(factory, mode) do
    factory_send(factory, Query.format("1851 ff %b", [Map.fetch!(@display_modes, mode)]))
  end

  @doc """
  Override the display with `text` (a string, encoded to Shift-JIS, or raw
  bytes with `raw: true`). At most 8 characters or 9 raw bytes.
  """
  @spec set_display_override(t(), String.t() | binary(), keyword()) :: :ok | error()
  def set_display_override(factory, text, opts \\ []) do
    blink = if Keyword.get(opts, :blink, false), do: 1, else: 0
    bytes = if Keyword.get(opts, :raw, false), do: text, else: SJIS.encode(text)

    if byte_size(bytes) > 9 do
      raise ArgumentError, "display text must encode to at most 9 bytes"
    end

    padded = bytes <> :binary.copy(<<0>>, 10 - byte_size(bytes))
    # First arg is a display buffer index; only 0 is known.
    factory_send(factory, Query.format("1852 ff %b %b 00 %*", [0, blink, padded]))
  end

  @doc "The device's firmware version as a BCD-decoded number."
  @spec device_version(t()) :: {:ok, non_neg_integer()} | error()
  def device_version(factory) do
    with {:ok, reply} <- factory_query(factory, Query.format("1813 ff")),
         {:ok, [version]} <- Query.scan(reply, "1813 00 00 %B") do
      {:ok, version}
    end
  end

  @doc """
  The device code: chip type, hardware id, firmware version and subversion.
  """
  @spec device_code(t()) ::
          {:ok,
           %{
             chip_type: byte(),
             hwid: byte(),
             version: non_neg_integer(),
             subversion: byte()
           }}
          | error()
  def device_code(factory) do
    with {:ok, reply} <- factory_query(factory, Query.format("1812 ff")),
         {:ok, [chip_type, hwid, subversion, version]} <-
           Query.scan(reply, "1812 00 %b %b %b %B") do
      {:ok, %{chip_type: chip_type, hwid: hwid, version: version, subversion: subversion}}
    end
  end

  @doc """
  A short device code string like `"S1.600"` (chip family, firmware
  version, subversion).
  """
  @spec descriptive_device_code(t()) :: {:ok, String.t()} | error()
  def descriptive_device_code(factory) do
    with {:ok, info} <- device_code(factory) do
      {:ok, descriptive_code(info.chip_type, info.version, info.subversion)}
    end
  end

  @doc false
  @spec descriptive_code(byte(), non_neg_integer(), byte()) :: String.t()
  def descriptive_code(chip_type, version, subversion) do
    version_string = Integer.to_string(version)
    major = String.at(version_string, 0) || "0"
    minor = String.at(version_string, 1) || ""
    sub = subversion |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0")
    "#{chip_prefix(chip_type)}#{major}.#{minor}#{sub}"
  end

  @doc "Front-panel switch and button state."
  @spec switch_status(t()) :: {:ok, [non_neg_integer()]} | error()
  def switch_status(factory) do
    with {:ok, reply} <- factory_query(factory, Query.format("1853 ff")) do
      Query.scan(reply, "1853 ff %w %b %b %w")
    end
  end

  @doc """
  Factory-transfer checksum (CRC-16/CCITT) over `data`.

  Options: `as_16bit: true` treats the input as little-endian 16-bit words;
  `seed:` sets the initial value (Hi-MD memory uses `0xA596`).
  """
  @spec checksum(binary(), keyword()) :: 0..0xFFFF
  def checksum(data, opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)

    words =
      if Keyword.get(opts, :as_16bit, false) do
        for <<word::little-16 <- data>>, do: word
      else
        :binary.bin_to_list(data)
      end

    crc = Enum.reduce(words, seed, fn element, crc -> crc_rounds(bxor(crc, element), 16) end)
    band(crc, 0xFFFF)
  end

  @doc "EEPROM checksum with the standard seeds (`0xA596` for Hi-MD)."
  @spec eeprom_checksum(binary(), keyword()) :: 0..0xFFFF
  def eeprom_checksum(data, opts \\ []) do
    seed = if Keyword.get(opts, :himd, false), do: 0xA596, else: 0
    checksum(data, as_16bit: true, seed: seed)
  end

  ## Internals

  defp factory_query(%__MODULE__{device: device}, query),
    do: Interface.send_query(device, query, factory?: true)

  defp factory_send(factory, query) do
    with {:ok, _reply} <- factory_query(factory, query), do: :ok
  end

  defp crc_rounds(crc, 0), do: crc

  defp crc_rounds(crc, remaining) do
    top_bit = band(crc, 0x8000)
    crc = band(bsl(crc, 1), 0xFFFF)
    crc = if top_bit != 0, do: bxor(crc, 0x1021), else: crc
    crc_rounds(crc, remaining - 1)
  end

  # The Hi-MD read/write header packs the length and memory type into one
  # byte: type in the high three bits, length in the low five.
  defp transfer_head(length, type), do: bor(bsl(memory_type(type), 5), band(length, 0x1F))

  defp drop_checksum(captured) when byte_size(captured) >= 2,
    do: binary_part(captured, 0, byte_size(captured) - 2)

  defp drop_checksum(_captured), do: <<>>

  defp rh1_address(address, type) do
    if memory_type(type) == @memory_types.mapped and address >= @rh1_dram_base do
      offset = address - @rh1_dram_base
      {:ok, div(offset, @rh1_sub_block_size), rem(offset, @rh1_sub_block_size)}
    else
      {:error, {:invalid_rh1_address, address}}
    end
  end

  defp memory_type(type) when is_atom(type), do: Map.fetch!(@memory_types, type)
  defp memory_type(type) when is_integer(type), do: type

  defp open_type(state) when is_atom(state), do: Map.fetch!(@open_types, state)
  defp open_type(state) when is_integer(state), do: state

  defp chip_prefix(0x20), do: "R"
  defp chip_prefix(0x21), do: "S"
  defp chip_prefix(0x22), do: "Hn"
  defp chip_prefix(0x23), do: "Hp"
  defp chip_prefix(0x24), do: "Hr"
  defp chip_prefix(0x25), do: "Hx"
  defp chip_prefix(chip_type), do: "#{chip_type}?"
end
