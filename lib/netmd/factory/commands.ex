defmodule NetMD.Factory.Commands do
  @moduledoc """
  Higher-level factory operations, ported from netmd-js's factory
  commands: bracketed reads and writes, firmware patching and raw UTOC
  sector access.

  **These manipulate device internals directly and can brick hardware.**
  The patch/unpatch routines are the exploit machinery Web MiniDisc uses
  to unlock features; use them only with a known patch set.
  """

  import Bitwise, only: [band: 2, bor: 2]

  alias NetMD.Crypto
  alias NetMD.Factory
  alias NetMD.Query

  @peripheral_bases %{netmd: 0x03802000, himd: 0x03804000}

  # A UTOC sector is 2352 bytes, transferred in 0x10-byte units.
  @transfer_unit 0x10
  @utoc_sector_size 2352
  @utoc_units div(@utoc_sector_size, @transfer_unit)

  @type error :: Factory.error()

  @doc "Show `text` on the display, taking over from the default readout."
  @spec display(Factory.t(), String.t() | binary(), keyword()) :: :ok | error()
  def display(factory, text, opts \\ []) do
    with :ok <- Factory.set_display_mode(factory, :override) do
      Factory.set_display_override(factory, text, Keyword.take(opts, [:blink, :raw]))
    end
  end

  @doc """
  Open, read and close a memory range in one call.

  With `encrypted: true` the range is opened encrypted and the result is
  decrypted unless `auto_decrypt: false`.
  """
  @spec clean_read(
          Factory.t(),
          non_neg_integer(),
          non_neg_integer(),
          Factory.memory_type(),
          keyword()
        ) :: {:ok, binary()} | error()
  def clean_read(factory, address, length, type, opts \\ []) do
    encrypted = Keyword.get(opts, :encrypted, false)
    auto_decrypt = Keyword.get(opts, :auto_decrypt, true)

    with :ok <-
           Factory.change_memory_state(factory, address, length, type, :read,
             encrypted: encrypted
           ),
         {:ok, data} <- Factory.read(factory, address, length, type),
         :ok <-
           Factory.change_memory_state(factory, address, length, type, :close,
             encrypted: encrypted
           ) do
      if encrypted and auto_decrypt do
        {:ok, Crypto.factory_transfer_decrypt(data)}
      else
        {:ok, data}
      end
    end
  end

  @doc """
  Open, write and close a memory range in one call.

  With `encrypted: true` the data is encrypted before writing unless
  `auto_encrypt: false`.
  """
  @spec clean_write(Factory.t(), non_neg_integer(), binary(), Factory.memory_type(), keyword()) ::
          :ok | error()
  def clean_write(factory, address, data, type, opts \\ []) do
    encrypted = Keyword.get(opts, :encrypted, false)
    auto_encrypt = Keyword.get(opts, :auto_encrypt, true)

    data =
      if encrypted and auto_encrypt, do: Crypto.factory_transfer_encrypt(data), else: data

    length = byte_size(data)

    with :ok <-
           Factory.change_memory_state(factory, address, length, type, :write,
             encrypted: encrypted
           ),
         :ok <- Factory.write(factory, address, data, type) do
      Factory.change_memory_state(factory, address, length, type, :close, encrypted: encrypted)
    end
  end

  @doc """
  Write arbitrarily long `data`, split into 0x10-byte cleanWrites.
  """
  @spec write_of_any_length(
          Factory.t(),
          non_neg_integer(),
          binary(),
          Factory.memory_type(),
          keyword()
        ) :: :ok | error()
  def write_of_any_length(factory, address, data, type, opts \\ []) do
    data
    |> chunks(@transfer_unit)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      case clean_write(factory, address + index * @transfer_unit, chunk, type, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Read a firmware patch slot, returning `%{address: patched_address,
  data: value}`.
  """
  @spec read_patch(Factory.t(), non_neg_integer(), keyword()) ::
          {:ok, %{address: non_neg_integer(), data: binary()}} | error()
  def read_patch(factory, patch_number, opts \\ []) do
    base = peripheral_base(opts) + patch_number * @transfer_unit

    with {:ok, address_bytes} <- clean_read(factory, base + 4, 4, :mapped),
         {:ok, [address]} <- Query.scan(address_bytes, "%<d"),
         {:ok, data} <- clean_read(factory, base + 8, 4, :mapped) do
      {:ok, %{address: address, data: data}}
    end
  end

  @doc """
  Install a firmware patch (method by Sir68k): redirect `address` to the
  4-byte `value` using patch slot `patch_number` of `total_patches`.
  """
  @spec patch(
          Factory.t(),
          non_neg_integer(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: :ok | error()
  def patch(factory, address, value, patch_number, total_patches, opts \\ [])
      when byte_size(value) == 4 do
    base = peripheral_base(opts) + patch_number * @transfer_unit
    control = peripheral_base(opts) + total_patches * @transfer_unit

    with :ok <- write_control(factory, control, [5, 12]),
         :ok <- toggle_patch_control(factory, base, &band(&1, 0xFE)),
         :ok <- toggle_patch_control(factory, base, &band(&1, 0xFD)),
         :ok <- clean_write(factory, base + 4, Query.format("%<d", [address]), :mapped),
         :ok <- clean_write(factory, base + 8, value, :mapped),
         :ok <- toggle_patch_control(factory, base, &bor(&1, 1)) do
      write_control(factory, control, [5, 9])
    end
  end

  @doc "Remove a firmware patch installed with `patch/6`."
  @spec unpatch(Factory.t(), non_neg_integer(), non_neg_integer(), keyword()) :: :ok | error()
  def unpatch(factory, patch_number, total_patches, opts \\ []) do
    base = peripheral_base(opts) + patch_number * @transfer_unit
    control = peripheral_base(opts) + total_patches * @transfer_unit

    with :ok <- write_control(factory, control, [5, 12]),
         :ok <- toggle_patch_control(factory, base, &band(&1, 0xFE)) do
      write_control(factory, control, [5, 9])
    end
  end

  @doc "Read a full 2352-byte UTOC sector from the disc-cache peripheral."
  @spec read_utoc_sector(Factory.t(), non_neg_integer()) :: {:ok, binary()} | error()
  def read_utoc_sector(factory, sector) do
    0..(@utoc_units - 1)
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, acc} ->
      case Factory.read_metadata_peripheral(
             factory,
             sector,
             index * @transfer_unit,
             @transfer_unit
           ) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  @doc "Write a full 2352-byte UTOC sector to the disc-cache peripheral."
  @spec write_utoc_sector(Factory.t(), non_neg_integer(), binary()) :: :ok | error()
  def write_utoc_sector(factory, sector, data) when byte_size(data) == @utoc_sector_size do
    data
    |> chunks(@transfer_unit)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      case Factory.write_metadata_peripheral(factory, sector, @transfer_unit * index, chunk) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  ## Internals

  defp write_control(factory, control, values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case clean_write(factory, control, <<value>>, :mapped) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp toggle_patch_control(factory, base, transform) do
    with {:ok, <<first, rest::binary>>} <- clean_read(factory, base, 4, :mapped) do
      clean_write(factory, base, <<transform.(first)>> <> rest, :mapped)
    end
  end

  defp peripheral_base(opts) do
    case Keyword.get(opts, :peripheral, :netmd) do
      base when is_integer(base) -> base
      name -> Map.fetch!(@peripheral_bases, name)
    end
  end

  # The reference's do-while writes one empty chunk for empty data.
  defp chunks(<<>>, _size), do: [<<>>]
  defp chunks(data, size) when byte_size(data) <= size, do: [data]

  defp chunks(data, size) do
    <<chunk::binary-size(^size), rest::binary>> = data
    [chunk | chunks(rest, size)]
  end
end
