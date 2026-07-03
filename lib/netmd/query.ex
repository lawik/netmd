defmodule Netmd.Query do
  @moduledoc """
  The NetMD query DSL: build command payloads and parse replies from
  printf/scanf-like format strings, as used by netmd-js and libnetmd.

  Format strings mix literal hex bytes with `%` fields:

  | Field | Meaning                                              |
  |-------|------------------------------------------------------|
  | `%b`  | 1-byte integer                                       |
  | `%w`  | 2-byte integer                                       |
  | `%d`  | 4-byte integer                                       |
  | `%q`  | 8-byte integer                                       |
  | `%x`  | binary preceded by 2 bytes of length                 |
  | `%s`  | null-terminated binary preceded by 2 bytes of length |
  | `%z`  | binary preceded by 1 byte of length                  |
  | `%*`  | raw binary (rest of input when scanning)             |
  | `%#`  | rest of input as binary (scan only)                  |
  | `%?`  | ignore one byte (scan only)                          |
  | `%B`  | BCD-encoded 1-byte number                            |
  | `%W`  | BCD-encoded 2-byte number                            |

  Integers are big-endian by default; `%<` overrides to little-endian for
  the following field (`%<d`), `%>` explicitly selects big-endian.

  ## Examples

      iex> Netmd.Query.format("1808 %b 00", [2])
      <<0x18, 0x08, 0x02, 0x00>>

      iex> Netmd.Query.scan(<<0x18, 0x08, 0x02, 0x00>>, "1808 %b 00")
      {:ok, [2]}
  """

  defmodule ScanError do
    @moduledoc "Raised by `Netmd.Query.scan!/2` when a reply does not match."
    defexception [:message]
  end

  @typedoc "A value produced or consumed by a `%` field."
  @type value :: integer() | binary()

  @number_bits %{?b => 8, ?w => 16, ?d => 32, ?q => 64}

  @doc """
  Build a binary query from `format` and `args`.

  Raises `ArgumentError` on malformed formats or mismatched arguments.
  """
  @spec format(String.t(), [value()]) :: binary()
  def format(format, args \\ []) when is_binary(format) and is_list(args) do
    format
    |> tokenize()
    |> build(args, [])
  end

  @doc """
  Parse `data` according to `format`, returning the field values in order.

  Literal bytes in the format must match the input exactly and the input
  must be fully consumed.
  """
  @spec scan(binary(), String.t()) :: {:ok, [value()]} | {:error, term()}
  def scan(data, format) when is_binary(data) and is_binary(format) do
    format
    |> tokenize()
    |> match(data, [])
  end

  @doc """
  Same as `scan/2` but raises `Netmd.Query.ScanError` on mismatch.
  """
  @spec scan!(binary(), String.t()) :: [value()]
  def scan!(data, format) do
    case scan(data, format) do
      {:ok, values} ->
        values

      {:error, reason} ->
        raise ScanError,
          message:
            "scan mismatch: #{inspect(reason)} for format #{inspect(format)} " <>
              "on #{Base.encode16(data, case: :lower)}"
    end
  end

  @doc """
  Encode a non-negative integer as binary-coded decimal in `length` bytes.

      iex> Netmd.Query.int_to_bcd(24, 1)
      <<0x24>>

      iex> Netmd.Query.int_to_bcd(9999, 2)
      <<0x99, 0x99>>
  """
  @spec int_to_bcd(non_neg_integer(), pos_integer()) :: binary()
  def int_to_bcd(value, length \\ 1) when value >= 0 do
    digits = Integer.digits(value)

    if length(digits) > length * 2 do
      raise ArgumentError, "#{value} cannot fit in #{length} bytes in BCD"
    end

    padding = List.duplicate(0, length * 2 - length(digits))

    for digit <- padding ++ digits, into: <<>>, do: <<digit::4>>
  end

  @doc """
  Decode a binary-coded decimal binary to an integer.

      iex> Netmd.Query.bcd_to_int(<<0x99, 0x99>>)
      9999
  """
  @spec bcd_to_int(binary()) :: non_neg_integer()
  def bcd_to_int(bcd) when is_binary(bcd) do
    for <<nibble::4 <- bcd>>, reduce: 0 do
      acc -> acc * 10 + nibble
    end
  end

  # Tokenizer: hex pairs become {:const, byte}, fields {:fmt, char, endianness}.
  # A space may fall between the two digits of a hex pair, matching the
  # reference parser.

  defp tokenize(format) do
    format
    |> String.to_charlist()
    |> tokenize(nil, [])
  end

  defp tokenize([], nil, acc), do: Enum.reverse(acc)

  defp tokenize([], _half, _acc) do
    raise ArgumentError, "dangling hex digit in format"
  end

  defp tokenize([?\s | rest], half, acc), do: tokenize(rest, half, acc)

  defp tokenize([?% | _rest], half, _acc) when half != nil do
    raise ArgumentError, "field started in the middle of a hex pair"
  end

  defp tokenize([?%, ?<, char | rest], nil, acc),
    do: tokenize(rest, nil, [{:fmt, char, :little} | acc])

  defp tokenize([?%, ?>, char | rest], nil, acc),
    do: tokenize(rest, nil, [{:fmt, char, :big} | acc])

  defp tokenize([?%, char | rest], nil, acc),
    do: tokenize(rest, nil, [{:fmt, char, :big} | acc])

  defp tokenize([char | rest], nil, acc), do: tokenize(rest, hex_digit(char), acc)

  defp tokenize([char | rest], half, acc),
    do: tokenize(rest, nil, [{:const, half * 16 + hex_digit(char)} | acc])

  defp hex_digit(char) when char in ?0..?9, do: char - ?0
  defp hex_digit(char) when char in ?a..?f, do: char - ?a + 10
  defp hex_digit(char) when char in ?A..?F, do: char - ?A + 10

  defp hex_digit(char) do
    raise ArgumentError, "unexpected character #{<<char>>} in format"
  end

  # format/2 walker

  defp build([], [], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp build([], leftover, _acc) do
    raise ArgumentError, "#{length(leftover)} unused arguments"
  end

  defp build([{:const, byte} | tokens], args, acc), do: build(tokens, args, [<<byte>> | acc])

  defp build([{:fmt, char, endianness} | tokens], [arg | args], acc)
       when is_map_key(@number_bits, char) and is_integer(arg) do
    bits = Map.fetch!(@number_bits, char)

    part =
      case endianness do
        :big -> <<arg::big-size(bits)>>
        :little -> <<arg::little-size(bits)>>
      end

    build(tokens, args, [part | acc])
  end

  defp build([{:fmt, ?x, _} | tokens], [arg | args], acc) when is_binary(arg) do
    build(tokens, args, [<<byte_size(arg)::big-16, arg::binary>> | acc])
  end

  defp build([{:fmt, ?s, _} | tokens], [arg | args], acc) when is_binary(arg) do
    build(tokens, args, [<<byte_size(arg) + 1::big-16, arg::binary, 0>> | acc])
  end

  defp build([{:fmt, ?z, _} | tokens], [arg | args], acc) when is_binary(arg) do
    build(tokens, args, [<<byte_size(arg)::8, arg::binary>> | acc])
  end

  defp build([{:fmt, ?*, _} | tokens], [arg | args], acc) when is_binary(arg) do
    build(tokens, args, [arg | acc])
  end

  # The reference implementation encodes both %B and %W through a one-byte
  # BCD conversion, so values are limited to 0..99 and %W always has a zero
  # high byte. Mirrored here to stay byte-for-byte equivalent.
  defp build([{:fmt, ?B, _} | tokens], [arg | args], acc) when arg in 0..99 do
    build(tokens, args, [int_to_bcd(arg, 1) | acc])
  end

  defp build([{:fmt, ?W, _} | tokens], [arg | args], acc) when arg in 0..99 do
    build(tokens, args, [<<0, int_to_bcd(arg, 1)::binary>> | acc])
  end

  defp build([{:fmt, char, _} | _tokens], [], _acc) do
    raise ArgumentError, "missing argument for %#{<<char>>}"
  end

  defp build([{:fmt, char, _} | _tokens], [arg | _], _acc) do
    raise ArgumentError, "bad argument #{inspect(arg)} for %#{<<char>>}"
  end

  # scan/2 walker

  defp match([], <<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp match([], rest, _acc), do: {:error, {:trailing_bytes, byte_size(rest)}}

  defp match([{:const, byte} | tokens], data, acc) do
    case data do
      <<^byte, rest::binary>> -> match(tokens, rest, acc)
      <<got, _::binary>> -> {:error, {:mismatch, byte, got}}
      <<>> -> {:error, :input_exhausted}
    end
  end

  defp match([{:fmt, ??, _} | tokens], data, acc) do
    case data do
      <<_skipped, rest::binary>> -> match(tokens, rest, acc)
      <<>> -> {:error, :input_exhausted}
    end
  end

  defp match([{:fmt, char, endianness} | tokens], data, acc)
       when is_map_key(@number_bits, char) do
    bits = Map.fetch!(@number_bits, char)

    result =
      case {endianness, data} do
        {:big, <<value::big-size(^bits), rest::binary>>} -> {value, rest}
        {:little, <<value::little-size(^bits), rest::binary>>} -> {value, rest}
        _ -> :error
      end

    case result do
      {value, rest} -> match(tokens, rest, [value | acc])
      :error -> {:error, :input_exhausted}
    end
  end

  defp match([{:fmt, char, _} | tokens], data, acc) when char in [?x, ?s] do
    case data do
      <<length::big-16, value::binary-size(length), rest::binary>> ->
        match(tokens, rest, [value | acc])

      _ ->
        {:error, :input_exhausted}
    end
  end

  defp match([{:fmt, ?z, _} | tokens], data, acc) do
    case data do
      <<length::8, value::binary-size(length), rest::binary>> ->
        match(tokens, rest, [value | acc])

      _ ->
        {:error, :input_exhausted}
    end
  end

  defp match([{:fmt, char, _} | tokens], data, acc) when char in [?*, ?#] do
    match(tokens, <<>>, [data | acc])
  end

  defp match([{:fmt, ?B, _} | tokens], data, acc) do
    case data do
      <<bcd::binary-size(1), rest::binary>> -> match(tokens, rest, [bcd_to_int(bcd) | acc])
      <<>> -> {:error, :input_exhausted}
    end
  end

  defp match([{:fmt, ?W, _} | tokens], data, acc) do
    case data do
      <<bcd::binary-size(2), rest::binary>> -> match(tokens, rest, [bcd_to_int(bcd) | acc])
      _ -> {:error, :input_exhausted}
    end
  end

  defp match([{:fmt, char, _} | _tokens], _data, _acc) do
    raise ArgumentError, "unrecognized format field %#{<<char>>}"
  end
end
