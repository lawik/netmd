defmodule Netmd.Device do
  @moduledoc """
  The fundamental NetMD USB exchange protocol, ported from netmd-js.

  Commands go out as vendor control transfers; replies are fetched by
  polling the device for a reply length and then reading that many bytes.
  Audio data moves over the bulk endpoints. This layer carries raw
  payloads only; `Netmd.Interface` gives them meaning.
  """

  alias Netmd.Devices
  alias Netmd.Transport

  @enforce_keys [:transport, :handle]
  defstruct [
    :transport,
    :handle,
    vendor_id: 0,
    product_id: 0,
    poll_interval_ms: 10,
    max_polls: 12
  ]

  @typedoc "An open NetMD device."
  @type t :: %__MODULE__{
          transport: module(),
          handle: Transport.handle(),
          vendor_id: 0..0xFFFF,
          product_id: 0..0xFFFF,
          poll_interval_ms: non_neg_integer(),
          max_polls: pos_integer()
        }

  @typedoc "A connected NetMD device, as reported by `list/1`."
  @type listing :: %{
          vendor_id: 0..0xFFFF,
          product_id: 0..0xFFFF,
          name: String.t(),
          flags: Devices.flags(),
          bus: pos_integer() | nil,
          address: pos_integer() | nil
        }

  # Vendor control requests
  @req_reply_length 0x01
  @req_command 0x80
  @req_reply 0x81
  @req_factory 0xFF

  @default_chunk_size 0x10000
  @bulk_timeout 10_000

  @doc """
  Open a NetMD device and drain any leftover reply from a previous session.

  Options:

    * `:transport` - `Netmd.Transport` implementation, defaults to
      `Netmd.Transport.Usb`
    * `:vendor_id`, `:product_id` - open a specific device instead of the
      first known one

  Remaining options are passed to the transport.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    transport = Keyword.get(opts, :transport, Netmd.Transport.Usb)

    with {:ok, handle, info} <- transport.open(opts) do
      device = %__MODULE__{
        transport: transport,
        handle: handle,
        vendor_id: info.vendor_id,
        product_id: info.product_id
      }

      case drain(device) do
        :ok ->
          {:ok, device}

        {:error, reason} ->
          transport.close(handle)
          {:error, reason}
      end
    end
  end

  @doc """
  List the connected NetMD devices without opening any of them.

  Each entry carries its USB ids, bus location and the display name and quirk
  flags from the known device table. Multiple identical models are told apart
  by their `:bus` and `:address`. Enumeration does not fail; an empty list means
  nothing is connected.

  Options:

    * `:transport` - `Netmd.Transport` implementation, defaults to
      `Netmd.Transport.Usb`

  Remaining options are passed to the transport. Raises `ArgumentError` for a
  transport that cannot enumerate devices.
  """
  @spec list(keyword()) :: [listing()]
  def list(opts \\ []) do
    transport = Keyword.get(opts, :transport, Netmd.Transport.Usb)

    # ensure_loaded so function_exported? sees a not-yet-loaded transport module.
    with {:module, _} <- Code.ensure_loaded(transport),
         true <- function_exported?(transport, :list, 1) do
      transport.list(opts) |> Enum.map(&describe/1)
    else
      _ -> raise ArgumentError, "transport #{inspect(transport)} does not support listing devices"
    end
  end

  defp describe(%{vendor_id: vendor_id, product_id: product_id} = location) do
    location
    |> Map.put(:name, Devices.name(vendor_id, product_id))
    |> Map.put(:flags, Devices.flags(vendor_id, product_id))
  end

  @doc "Release the device."
  @spec close(t()) :: :ok
  def close(%__MODULE__{transport: transport, handle: handle}), do: transport.close(handle)

  @doc "Display name from the known device table."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{vendor_id: vendor_id, product_id: product_id}),
    do: Devices.name(vendor_id, product_id)

  @doc "Quirk flags from the known device table."
  @spec flags(t()) :: Devices.flags()
  def flags(%__MODULE__{vendor_id: vendor_id, product_id: product_id}),
    do: Devices.flags(vendor_id, product_id)

  @doc """
  Poll the length of the pending reply. `{:ok, 0}` means no reply yet.
  """
  @spec reply_length(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reply_length(%__MODULE__{transport: transport, handle: handle}) do
    case transport.control_in(handle, @req_reply_length, 0, 0, 4) do
      {:ok, <<_, _, length, _rest::binary>>} -> {:ok, length}
      {:ok, _short} -> {:error, :short_poll}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send a raw command payload. Set `factory?: true` for the factory command
  set (only do this if you know what you are doing).
  """
  @spec send_command(t(), binary(), keyword()) :: :ok | {:error, term()}
  def send_command(%__MODULE__{transport: transport, handle: handle}, command, opts \\ []) do
    request = if Keyword.get(opts, :factory?, false), do: @req_factory, else: @req_command
    transport.control_out(handle, request, 0, 0, command)
  end

  @doc """
  Read the reply to the last command, polling until the device has one.

  Polling backs off exponentially from `poll_interval_ms` and gives up
  after `max_polls` attempts with `{:error, :no_reply}`. Options:

    * `factory?: true` - read a factory command reply
    * `length: n` - skip polling and read exactly `n` bytes
  """
  @spec read_reply(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_reply(%__MODULE__{} = device, opts \\ []) do
    factory? = Keyword.get(opts, :factory?, false)

    with {:ok, length} <- awaited_length(device, Keyword.get(opts, :length)),
         request = if(factory?, do: @req_factory, else: @req_reply),
         {:ok, data} <- device.transport.control_in(device.handle, request, 0, 0, length) do
      # The reference implementation polls once more after reading.
      _ = reply_length(device)
      {:ok, data}
    end
  end

  @doc """
  Read `length` bytes from the bulk endpoint in `:chunk_size` chunks
  (default `0x10000`). An optional `:progress` function is called with
  `(total, read_so_far)` after each chunk.
  """
  @spec read_bulk(t(), non_neg_integer(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_bulk(%__MODULE__{} = device, length, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    timeout = Keyword.get(opts, :timeout, @bulk_timeout)
    progress = Keyword.get(opts, :progress)

    read_bulk_chunks(device, length, 0, chunk_size, timeout, progress, [])
  end

  @doc "Write data to the bulk OUT endpoint."
  @spec write_bulk(t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_bulk(%__MODULE__{transport: transport, handle: handle}, data, opts \\ []) do
    transport.bulk_out(handle, data, Keyword.get(opts, :timeout, @bulk_timeout))
  end

  defp drain(device) do
    case reply_length(device) do
      {:ok, 0} ->
        :ok

      {:ok, _pending} ->
        case read_reply(device) do
          {:ok, _drained} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp awaited_length(_device, length) when is_integer(length), do: {:ok, length}
  defp awaited_length(device, nil), do: await_reply(device, 0)

  defp await_reply(%__MODULE__{max_polls: max}, attempt) when attempt >= max,
    do: {:error, :no_reply}

  defp await_reply(device, attempt) do
    case reply_length(device) do
      {:ok, 0} ->
        # Exponential backoff, like the reference implementation.
        Process.sleep(device.poll_interval_ms * Integer.pow(2, attempt))
        await_reply(device, attempt + 1)

      other ->
        other
    end
  end

  defp read_bulk_chunks(_device, length, done, _chunk, _timeout, _progress, acc)
       when done >= length do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp read_bulk_chunks(device, length, done, chunk_size, timeout, progress, acc) do
    request = min(length - done, chunk_size)

    case device.transport.bulk_in(device.handle, request, timeout) do
      {:ok, <<>>} ->
        {:error, :bulk_read_stalled}

      {:ok, data} ->
        done = done + byte_size(data)
        if progress, do: progress.(length, done)
        read_bulk_chunks(device, length, done, chunk_size, timeout, progress, [data | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end
end
