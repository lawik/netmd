defmodule Netmd.Track do
  @moduledoc """
  A track to download to the recorder, ported from netmd-js's MDTrack.

  Audio data must already be in the wire format: raw PCM (big-endian
  16-bit stereo at 44100 Hz) or pre-encoded ATRAC3 for the LP modes.
  Packets are encrypted with a random key wrapped by the key encryption
  key, chained CBC across chunks.
  """

  alias Netmd.Crypto

  @enforce_keys [:title, :format, :data]
  defstruct [:title, :format, :data, :full_width_title, chunk_size: 0x00100000, raw_key: nil]

  @typedoc "Wire format of the audio data."
  @type format :: :pcm | :l105kbps | :lp2 | :lp4

  @typedoc "A track ready for download."
  @type t :: %__MODULE__{
          title: String.t(),
          format: format(),
          data: binary(),
          full_width_title: String.t() | nil,
          chunk_size: pos_integer(),
          raw_key: <<_::64>> | nil
        }

  @frame_sizes %{pcm: 2048, l105kbps: 152, lp2: 192, lp4: 96}
  @wireformats %{pcm: 0x00, l105kbps: 0x90, lp2: 0x94, lp4: 0xA8}
  # Disc format byte for each wire format (SP stereo, LP2, LP2, LP4).
  @disc_for_wire %{pcm: 6, l105kbps: 2, lp2: 2, lp4: 0}

  @doc "Frame size in bytes for the track's wire format."
  @spec frame_size(t()) :: pos_integer()
  def frame_size(%__MODULE__{format: format}), do: Map.fetch!(@frame_sizes, format)

  @doc "Wire format byte sent to the device."
  @spec wireformat(t()) :: byte()
  def wireformat(%__MODULE__{format: format}), do: Map.fetch!(@wireformats, format)

  @doc "Default disc format byte for the track's wire format."
  @spec disc_format(t()) :: byte()
  def disc_format(%__MODULE__{format: format}), do: Map.fetch!(@disc_for_wire, format)

  @doc "Data size in bytes, padded up to a whole number of frames."
  @spec total_size(t()) :: pos_integer()
  def total_size(%__MODULE__{data: data} = track) do
    frame = frame_size(track)
    remainder = rem(byte_size(data), frame)

    case remainder do
      0 -> byte_size(data)
      _short -> byte_size(data) + frame - remainder
    end
  end

  @doc "Number of frames in the (padded) data."
  @spec frame_count(t()) :: non_neg_integer()
  def frame_count(%__MODULE__{} = track), do: div(total_size(track), frame_size(track))

  @doc """
  The content ID all open implementations use.
  """
  @spec content_id() :: <<_::160>>
  def content_id() do
    <<0x01, 0x0F, 0x50, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x48, 0xA2, 0x8D, 0x3E, 0x1A, 0x3B,
      0x0C, 0x44, 0xAF, 0x2F, 0xA0>>
  end

  @doc """
  The key encryption key all open implementations use.
  """
  @spec kek() :: <<_::64>>
  def kek() do
    <<0x14, 0xE3, 0x83, 0x4E, 0xE2, 0xD3, 0xCC, 0xA5>>
  end

  @doc """
  Stream of `{key, iv, encrypted_data}` packets for `Netmd.Interface.send_track/8`.

  The data is encrypted with a random key (set `:raw_key` on the struct
  for a deterministic stream); the packet key is that key unwrapped with
  the KEK. The IV chains from the last ciphertext block of the previous
  chunk.
  """
  @spec packets(t()) :: Enumerable.t()
  def packets(%__MODULE__{} = track) do
    raw_key = track.raw_key || :crypto.strong_rand_bytes(8)
    packet_key = Crypto.des_ecb_decrypt(kek(), raw_key)

    track
    |> padded_data()
    |> chunks(track.chunk_size)
    |> Stream.transform(<<0::64>>, fn chunk, iv ->
      encrypted = Crypto.des_cbc_encrypt(raw_key, iv, chunk)
      next_iv = binary_part(encrypted, byte_size(encrypted) - 8, 8)
      {[{packet_key, iv, encrypted}], next_iv}
    end)
  end

  defp padded_data(%__MODULE__{data: data} = track) do
    data <> :binary.copy(<<0>>, total_size(track) - byte_size(data))
  end

  # The first chunk is shortened by the 24-byte packet header.
  defp chunks(data, chunk_size) do
    Stream.unfold({data, chunk_size - 24}, fn
      {<<>>, _size} ->
        nil

      {rest, size} ->
        take = min(size, byte_size(rest))
        <<chunk::binary-size(^take), rest::binary>> = rest
        {chunk, {rest, chunk_size}}
    end)
  end
end
