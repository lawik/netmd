defmodule NetMD.TitlesTest do
  use ExUnit.Case, async: true

  alias NetMD.SJIS
  alias NetMD.Titles

  doctest NetMD.SJIS

  vectors =
    "../fixtures/title_vectors.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> JSON.decode!()

  @title_vectors vectors["titles"]
  @decode_vectors vectors["decode"]
  @range_vectors vectors["ranges"]

  test "SJIS encoding matches jconv" do
    for %{"input" => input, "encoded" => encoded} <- @title_vectors do
      assert SJIS.encode(input) == Base.decode16!(encoded, case: :lower),
             "encode #{inspect(input)}"
    end
  end

  test "SJIS encoded length matches reference" do
    for %{"input" => input, "length_sjis" => length} <- @title_vectors do
      assert SJIS.encoded_length(input) == length, "length of #{inspect(input)}"
    end
  end

  test "SJIS decoding matches jconv" do
    for %{"input" => input, "decoded" => decoded} <- @decode_vectors do
      assert SJIS.decode(Base.decode16!(input, case: :lower)) == decoded,
             "decode #{inspect(input)}"
    end
  end

  test "half-width sanitization matches reference" do
    for %{"input" => input, "sanitized_half" => expected} <- @title_vectors do
      assert Titles.sanitize_half_width(input) == expected, "sanitize #{inspect(input)}"
    end
  end

  test "full-width sanitization matches reference" do
    for %{"input" => input, "sanitized_full" => expected} <- @title_vectors do
      assert Titles.sanitize_full_width(input) == expected, "sanitize #{inspect(input)}"
    end
  end

  test "aggressive sanitization matches reference" do
    for %{"input" => input, "aggressive" => expected} <- @title_vectors do
      assert Titles.aggressive_sanitize(input) == expected, "sanitize #{inspect(input)}"
    end
  end

  test "half-width length matches reference" do
    for %{"input" => input, "half_width_length" => expected} <- @title_vectors do
      assert Titles.half_width_length(input) == expected, "length of #{inspect(input)}"
    end
  end

  test "range conversion matches reference" do
    for %{"input" => input, "full_width" => expected} <- @range_vectors do
      assert Titles.half_width_to_full_width_range(input) == expected
    end
  end
end
