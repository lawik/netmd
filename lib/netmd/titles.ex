defmodule Netmd.Titles do
  @moduledoc """
  Title sanitization for MiniDisc TOC entries, ported from netmd-js.

  Half-width titles allow ASCII plus half-width katakana; full-width
  titles allow the two-byte Shift-JIS character set. Both sanitizers fall
  back to an aggressive ASCII-only strip when the result would not encode
  cleanly. The mapping tables are extracted verbatim from the reference
  source by `tools/gen_title_tables.ts`.
  """

  alias Netmd.SJIS

  @tables_path Path.join(:code.priv_dir(:netmd) || "priv", "titles_tables.json")
  @external_resource @tables_path

  tables = @tables_path |> File.read!() |> JSON.decode!()

  # Keys that are a single UTF-16 unit; longer keys can never match the
  # reference's per-character lookups.
  single_unit? = fn key -> match?([_], String.to_charlist(key)) end

  to_codepoint_map = fn map ->
    for {key, value} <- map, single_unit?.(key), into: %{} do
      [codepoint] = String.to_charlist(key)
      {codepoint, value}
    end
  end

  @jp_map to_codepoint_map.(tables["jp"])
  @ru_map to_codepoint_map.(tables["ru"])
  @de_map to_codepoint_map.(tables["de"])
  @half_map to_codepoint_map.(tables["half"])
  @range_map to_codepoint_map.(tables["range"])
  @diacritics_map to_codepoint_map.(tables["diacritics"])

  @allowed_half_kana tables["half"] |> Map.values() |> MapSet.new()
  @multibyte_chars tables["multibyte"]
                   |> Enum.map(fn char ->
                     [codepoint] = String.to_charlist(char)
                     codepoint
                   end)
                   |> MapSet.new()

  @dakuten_possible tables["dakuten_possible"] |> String.to_charlist() |> MapSet.new()
  @handakuten_possible tables["handakuten_possible"] |> String.to_charlist() |> MapSet.new()

  @dakuten_marks [0x309B, 0x3099, 0xFF9E]
  @handakuten_marks [0x309C, 0x309A, 0xFF9F]

  @doc """
  Sanitize a title for the full-width (two bytes per character) TOC slot.

  With `just_remap: true` only the character remapping runs, without the
  encoding check and fallback.
  """
  @spec sanitize_full_width(String.t(), keyword()) :: String.t()
  def sanitize_full_width(title, opts \\ []) do
    remapped =
      title
      |> String.to_charlist()
      |> Enum.map_join(&remap_full_width/1)

    if Keyword.get(opts, :just_remap, false) do
      remapped
    else
      encoded = SJIS.encode(remapped)

      # Every character of a valid full-width title encodes to 2 bytes.
      if byte_size(encoded) == utf16_length(title) * 2 do
        SJIS.decode(encoded)
      else
        aggressive_sanitize(title)
      end
    end
  end

  @doc """
  Sanitize a title for the half-width (ASCII and half-width kana) TOC slot.
  """
  @spec sanitize_half_width(String.t()) :: String.t()
  def sanitize_half_width(title) do
    # The reference remaps to full-width first, flattens (han)dakuten
    # marks into their combined characters, then maps back down. Note the
    # fallback operates on the remapped title, quirks included.
    remapped =
      title
      |> sanitize_full_width(just_remap: true)
      |> String.to_charlist()
      |> Enum.reverse()
      |> flatten_dakuten(:normal, [])

    new_title = Enum.map_join(remapped, &half_width_char/1)

    if SJIS.encoded_length(new_title) == half_width_length(List.to_string(remapped)) do
      new_title
    else
      aggressive_sanitize(List.to_string(remapped))
    end
  end

  @doc """
  Strip a title down to plain ASCII.
  """
  @spec aggressive_sanitize(String.t()) :: String.t()
  def aggressive_sanitize(title) do
    title
    |> remove_diacritics()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/u, "")
  end

  @doc """
  Replace diacritics with their base characters, like the diacritics
  package used by the reference.
  """
  @spec remove_diacritics(String.t()) :: String.t()
  def remove_diacritics(string) do
    string
    |> String.to_charlist()
    |> Enum.map_join(fn codepoint ->
      Map.get(@diacritics_map, codepoint, <<codepoint::utf8>>)
    end)
  end

  @doc """
  Length of a title in half-width character cells; voiced kana take two.
  """
  @spec half_width_length(String.t()) :: non_neg_integer()
  def half_width_length(title) do
    title
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, acc ->
      acc + utf16_units(codepoint) +
        if MapSet.member?(@multibyte_chars, codepoint), do: 1, else: 0
    end)
  end

  @doc """
  Convert a track range like `"1-5"` to its full-width form. Characters
  outside `0-9`, `-`, `/` and `;` are dropped.
  """
  @spec half_width_to_full_width_range(String.t()) :: String.t()
  def half_width_to_full_width_range(range) do
    range
    |> String.to_charlist()
    |> Enum.map_join(&Map.get(@range_map, &1, ""))
  end

  defp remap_full_width(codepoint) do
    mapped = Map.get(@jp_map, codepoint, <<codepoint::utf8>>)
    mapped = single_lookup(@ru_map, mapped)
    single_lookup(@de_map, mapped)
  end

  defp single_lookup(map, string) do
    case String.to_charlist(string) do
      [codepoint] -> Map.get(map, codepoint, string)
      _ -> string
    end
  end

  # Port of the reference's reversed-iteration state machine that merges
  # a kana followed by a (han)dakuten mark into the combined codepoint.
  # Unmatched marks are dropped.
  defp flatten_dakuten([], _state, acc), do: acc

  defp flatten_dakuten([codepoint | rest], state, acc) do
    cond do
      state == :dakuten and MapSet.member?(@dakuten_possible, codepoint) ->
        flatten_dakuten(rest, :normal, [codepoint + 1 | acc])

      state in [:dakuten, :handakuten] and MapSet.member?(@handakuten_possible, codepoint) ->
        flatten_dakuten(rest, :normal, [codepoint + 2 | acc])

      codepoint in @dakuten_marks ->
        flatten_dakuten(rest, :dakuten, acc)

      codepoint in @handakuten_marks ->
        flatten_dakuten(rest, :handakuten, acc)

      true ->
        flatten_dakuten(rest, :normal, [codepoint | acc])
    end
  end

  defp half_width_char(codepoint) do
    check(<<codepoint::utf8>>) ||
      check(Map.get(@diacritics_map, codepoint, <<codepoint::utf8>>)) ||
      " "
  end

  defp check(string) do
    [first | _] = String.to_charlist(string)

    cond do
      match?([_], String.to_charlist(string)) and Map.has_key?(@half_map, first) ->
        Map.fetch!(@half_map, first)

      first < 0x7F ->
        string

      MapSet.member?(@allowed_half_kana, string) ->
        string

      true ->
        nil
    end
  end

  defp utf16_length(string) do
    string
    |> String.to_charlist()
    |> Enum.reduce(0, &(utf16_units(&1) + &2))
  end

  defp utf16_units(codepoint) when codepoint > 0xFFFF, do: 2
  defp utf16_units(_codepoint), do: 1
end
