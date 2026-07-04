defmodule NetMD.Audio do
  @moduledoc """
  File headers for audio uploaded from a disc, ported from netmd-js.

  SP tracks get an AEA header (the ATRAC1 container ffmpeg understands);
  LP tracks get a WAV header with the ATRAC3 format tag.
  """

  @aea_header_size 2048

  @doc """
  Build an AEA header for SP audio.
  """
  @spec aea_header(String.t(), channels :: 1..2, soundgroups :: non_neg_integer()) :: binary()
  def aea_header(name \\ "", channels \\ 2, soundgroups \\ 1) do
    encoded_name = binary_part(name, 0, min(byte_size(name), 256))

    header =
      <<@aea_header_size::little-32>> <>
        encoded_name <>
        :binary.copy(<<0>>, 256 - byte_size(encoded_name)) <>
        <<soundgroups::little-32, channels, 0>> <>
        :binary.copy(<<0::little-32>>, 8) <>
        <<0::little-32, 0::little-32, 0::little-32>>

    header <> :binary.copy(<<0>>, @aea_header_size - byte_size(header))
  end

  @doc """
  Build a WAV header for LP2 (`2`) or LP4 (`0`) format audio of
  `bytes` length.
  """
  @spec wav_header(format :: 0 | 2, bytes :: non_neg_integer()) :: binary()
  def wav_header(format, bytes) do
    {bytes_per_frame, joint_stereo} =
      case format do
        2 -> {192, 0}
        0 -> {96, 1}
      end

    bytes_per_second = div(bytes_per_frame * 44_100, 512)

    "RIFF" <>
      <<bytes + 60::little-32>> <>
      "WAVEfmt " <>
      <<32::little-32>> <>
      <<0x270::little-16, 2::little-16, 44_100::little-32, bytes_per_second::little-32,
        bytes_per_frame * 2::little-16, 0, 0>> <>
      <<14::little-16, 1::little-16, bytes_per_frame::little-32, joint_stereo::little-16,
        joint_stereo::little-16, 1::little-16, 0::little-16>> <>
      "data" <>
      <<bytes::little-32>>
  end
end
