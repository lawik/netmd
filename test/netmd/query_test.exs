defmodule Netmd.QueryTest do
  use ExUnit.Case, async: true

  alias Netmd.Query

  doctest Netmd.Query

  # Cases ported from netmd-js src/query-utils.test.ts

  describe "format/2" do
    test "format const" do
      assert Query.format("00 00 00 01") == <<0x00, 0x00, 0x00, 0x01>>
    end

    test "format string" do
      assert Query.format("00 00 00 %x", ["ciao"]) ==
               <<0x00, 0x00, 0x00, 0x00, 0x04, 0x63, 0x69, 0x61, 0x6F>>
    end

    test "format binary" do
      assert Query.format("00 00 00 %*", [<<0xFF, 0x00>>]) == <<0x00, 0x00, 0x00, 0xFF, 0x00>>
    end

    test "format raw string" do
      assert Query.format("00 00 00 %*", ["abc"]) == <<0x00, 0x00, 0x00, 0x61, 0x62, 0x63>>
    end

    test "format null terminated string" do
      assert Query.format("00 00 00 %s", ["ciao"]) ==
               <<0x00, 0x00, 0x00, 0x00, 0x05, 0x63, 0x69, 0x61, 0x6F, 0x00>>
    end

    test "format byte" do
      assert Query.format("00 00 00 %b", [0xFF]) == <<0x00, 0x00, 0x00, 0xFF>>
    end

    test "format word" do
      assert Query.format("00 00 00 %w", [0xFF01]) == <<0x00, 0x00, 0x00, 0xFF, 0x01>>
    end

    test "format double word" do
      assert Query.format("00 00 00 %d", [0xFF019922]) ==
               <<0x00, 0x00, 0x00, 0xFF, 0x01, 0x99, 0x22>>
    end

    test "format double word little endian" do
      assert Query.format("00 00 00 %<d", [0xFF019922]) ==
               <<0x00, 0x00, 0x00, 0x22, 0x99, 0x01, 0xFF>>
    end

    test "format quad word" do
      assert Query.format("00 00 00 %q", [0xFF019922229901FF]) ==
               <<0x00, 0x00, 0x00, 0xFF, 0x01, 0x99, 0x22, 0x22, 0x99, 0x01, 0xFF>>
    end

    test "format 1-byte BCD" do
      assert Query.format("00 00 00 %B", [24]) == <<0x00, 0x00, 0x00, 0x24>>
    end

    test "format 2-byte BCD" do
      assert Query.format("00 00 00 %W", [24]) == <<0x00, 0x00, 0x00, 0x00, 0x24>>
    end
  end

  describe "scan/2" do
    test "parse const" do
      assert Query.scan(<<0x00, 0x00, 0x00, 0x01>>, "00 00 00 01") == {:ok, []}
    end

    test "parse wildcard" do
      assert Query.scan(<<0x00, 0x00, 0x00, 0x01>>, "00 00 %? 01") == {:ok, []}
    end

    test "trailing wildcard tolerates end of input" do
      # netmd-js's %? is a no-op past the end of input, so a %x that consumes the
      # whole reply followed by a trailing %? must still match. Real replies rely
      # on this: playback_status2 on the MZ-N707 ends exactly at the %x blob.
      assert Query.scan(<<0x00, 0x00>>, "00 00 %?") == {:ok, []}
      assert Query.scan(<<0x00, 0x02, 0xAA, 0xBB>>, "%x %?") == {:ok, [<<0xAA, 0xBB>>]}
    end

    test "parse remaining bytes" do
      assert Query.scan(<<0x00, 0x00, 0x00, 0x01>>, "00 00 %*") == {:ok, [<<0x00, 0x01>>]}
    end

    test "parse string" do
      assert Query.scan(<<0x00, 0x00, 0x00, 0x04, 0x63, 0x69, 0x61, 0x6F>>, "00 00 %x") ==
               {:ok, ["ciao"]}
    end

    test "parse null terminated string" do
      assert Query.scan(<<0x00, 0x00, 0x00, 0x05, 0x63, 0x69, 0x61, 0x6F, 0x00>>, "00 00 %s") ==
               {:ok, [<<0x63, 0x69, 0x61, 0x6F, 0x00>>]}
    end

    test "parse byte" do
      assert Query.scan(<<0x00, 0x00, 0xFF>>, "00 00 %b") == {:ok, [0xFF]}
    end

    test "parse word" do
      assert Query.scan(<<0x00, 0x00, 0xFF, 0x01>>, "00 00 %w") == {:ok, [0xFF01]}
    end

    test "parse double word" do
      assert Query.scan(<<0x00, 0x00, 0xFF, 0x01, 0xAA, 0x10>>, "00 00 %d") ==
               {:ok, [0xFF01AA10]}
    end

    test "parse quad word" do
      assert Query.scan(
               <<0x00, 0x00, 0xFF, 0x01, 0xAA, 0x10, 0x10, 0xAA, 0x01, 0xFF>>,
               "00 00 %q"
             ) ==
               {:ok, [0xFF01AA1010AA01FF]}
    end

    test "mismatched const errors" do
      assert {:error, {:mismatch, 0x01, 0x02}} = Query.scan(<<0x02>>, "01")
    end

    test "trailing bytes error" do
      assert {:error, {:trailing_bytes, 1}} = Query.scan(<<0x01, 0x02>>, "01")
    end

    test "scan! raises on mismatch" do
      assert_raise Query.ScanError, fn -> Query.scan!(<<0x02>>, "01") end
    end
  end

  describe "BCD conversion" do
    test "1 byte conversion" do
      assert 99 |> Query.int_to_bcd(1) |> Query.bcd_to_int() == 99
    end

    test "2 byte conversion" do
      assert 9999 |> Query.int_to_bcd(2) |> Query.bcd_to_int() == 9999
    end

    test "3 byte conversion" do
      assert 999_999 |> Query.int_to_bcd(3) |> Query.bcd_to_int() == 999_999
    end

    test "4 byte conversion" do
      assert 99_999_999 |> Query.int_to_bcd(4) |> Query.bcd_to_int() == 99_999_999
    end

    test "overflow raises" do
      assert_raise ArgumentError, fn -> Query.int_to_bcd(100, 1) end
    end
  end

  # Golden vectors generated from netmd-js (tools/gen_query_vectors.ts)

  vectors =
    "../fixtures/query_vectors.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> JSON.decode!()

  describe "golden vectors" do
    @format_vectors vectors["format"]
    @scan_vectors vectors["scan"]
    @bcd_vectors vectors["bcd"]

    defp from_json(%{"t" => "int", "v" => value}), do: String.to_integer(value)
    defp from_json(%{"t" => "bytes", "v" => hex}), do: Base.decode16!(hex, case: :lower)

    test "format vectors match netmd-js byte for byte" do
      for %{"format" => format, "args" => args, "result" => result} <- @format_vectors do
        args = Enum.map(args, &from_json/1)
        expected = Base.decode16!(result, case: :lower)

        assert Query.format(format, args) == expected,
               "format #{inspect(format)} with #{inspect(args)}"
      end
    end

    test "scan vectors match netmd-js values" do
      for %{"format" => format, "input" => input, "results" => results} <- @scan_vectors do
        input = Base.decode16!(input, case: :lower)
        expected = Enum.map(results, &from_json/1)

        assert Query.scan(input, format) == {:ok, expected},
               "scan #{inspect(format)} on #{inspect(input)}"
      end
    end

    test "BCD vectors match netmd-js" do
      for %{"value" => value, "length" => length, "bcd" => bcd, "roundtrip" => roundtrip} <-
            @bcd_vectors do
        encoded = Query.int_to_bcd(value, length)
        assert :binary.decode_unsigned(encoded) == bcd
        assert Query.bcd_to_int(encoded) == roundtrip
      end
    end
  end
end
