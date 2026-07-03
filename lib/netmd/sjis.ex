defmodule Netmd.SJIS do
  @moduledoc """
  Shift-JIS codec for NetMD titles.

  Table-driven, generated from jconv (the codec netmd-js uses) by
  `tools/gen_sjis_tables.ts`, including its quirks: unmappable characters
  encode to the katakana middle dot `0x8145` and invalid byte sequences
  decode to `・`.

  One divergence: characters outside the Basic Multilingual Plane encode
  to a single `・` where the reference produces two.
  """

  @encode_path Path.join(:code.priv_dir(:netmd) || "priv", "sjis/encode.tsv")
  @decode_path Path.join(:code.priv_dir(:netmd) || "priv", "sjis/decode.tsv")
  @external_resource @encode_path
  @external_resource @decode_path

  @unknown_bytes <<0x81, 0x45>>
  @unknown_char "・"

  parse_tsv = fn path ->
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [left, right] = String.split(line, "\t")
      {left, right}
    end)
  end

  @encode_table Map.new(parse_tsv.(@encode_path), fn {codepoint, bytes} ->
                  {String.to_integer(codepoint, 16), Base.decode16!(bytes, case: :lower)}
                end)

  @decode_table Map.new(parse_tsv.(@decode_path), fn {bytes, codepoint} ->
                  {Base.decode16!(bytes, case: :lower),
                   <<String.to_integer(codepoint, 16)::utf8>>}
                end)

  @lead_bytes @decode_table
              |> Map.keys()
              |> Enum.filter(&(byte_size(&1) == 2))
              |> Enum.map(fn <<lead, _>> -> lead end)
              |> MapSet.new()

  @doc """
  Encode a UTF-8 string to Shift-JIS bytes.

      iex> Netmd.SJIS.encode("abc")
      "abc"

      iex> Netmd.SJIS.encode("カナ")
      <<0x83, 0x4A, 0x83, 0x69>>
  """
  @spec encode(String.t()) :: binary()
  def encode(string) when is_binary(string) do
    for <<codepoint::utf8 <- string>>, into: <<>> do
      encode_codepoint(codepoint)
    end
  end

  @doc """
  Byte length of the string once encoded to Shift-JIS.
  """
  @spec encoded_length(String.t()) :: non_neg_integer()
  def encoded_length(string), do: byte_size(encode(string))

  @doc """
  Decode Shift-JIS bytes to a UTF-8 string.

      iex> Netmd.SJIS.decode(<<0x83, 0x4A, 0x83, 0x69>>)
      "カナ"
  """
  @spec decode(binary()) :: String.t()
  def decode(data) when is_binary(data), do: decode(data, [])

  defp encode_codepoint(codepoint) when codepoint < 0x80, do: <<codepoint>>

  defp encode_codepoint(codepoint), do: Map.get(@encode_table, codepoint, @unknown_bytes)

  defp decode(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode(<<byte, rest::binary>>, acc) when byte < 0x80,
    do: decode(rest, [<<byte>> | acc])

  defp decode(<<byte, rest::binary>> = data, acc) do
    if MapSet.member?(@lead_bytes, byte) do
      decode_pair(data, acc)
    else
      decode(rest, [Map.get(@decode_table, <<byte>>, @unknown_char) | acc])
    end
  end

  defp decode_pair(<<pair::binary-size(2), rest::binary>>, acc) do
    decode(rest, [Map.get(@decode_table, pair, @unknown_char) | acc])
  end

  defp decode_pair(<<_lone_lead>>, acc) do
    decode(<<>>, [@unknown_char | acc])
  end
end
