defmodule Netmd.Interface do
  @moduledoc """
  The NetMD command set, ported from netmd-js.

  Every command is a query built with `Netmd.Query`, sent through
  `Netmd.Device` with a status byte prepended, and a reply parsed the same
  way. Replies carry an AV/C response status: `accepted`, `implemented`
  and late `interim` responses succeed; `not_implemented` and `rejected`
  become error tuples; `interim` is retried with backoff.

  Track numbers are zero-based, as in the reference implementations.
  """

  alias Netmd.Crypto
  alias Netmd.Device
  alias Netmd.EKB
  alias Netmd.Query
  alias Netmd.SJIS
  alias Netmd.Titles

  @type error :: {:error, term()}

  @zero_iv <<0, 0, 0, 0, 0, 0, 0, 0>>

  # Command status bytes
  @status_control 0x00
  @status_specific_inquiry 0x02
  # Response status bytes
  @status_not_implemented 0x08
  @status_accepted 0x09
  @status_rejected 0x0A
  @status_implemented 0x0C
  @status_interim 0x0F

  @max_interim_attempts 4
  @interim_retry_ms 100

  # Descriptor identifiers (text databases and status blocks)
  @descriptors %{
    disc_title_td: "10 1801",
    audio_utoc1_td: "10 1802",
    audio_utoc4_td: "10 1803",
    dsi_td: "10 1804",
    audio_contents_td: "10 1001",
    root_td: "10 1000",
    disc_subunit_identifier: "00",
    operating_status_block: "80 00"
  }

  @descriptor_actions %{open_read: "01", open_write: "03", close: "00"}

  @playback_actions %{play: 0x75, pause: 0x7D, fast_forward: 0x39, rewind: 0x49}

  @track_movements %{previous: 0x0002, next: 0x8001, restart: 0x0001}

  ## Plumbing

  @doc """
  Send a query and read its parsed reply payload (status byte stripped).

  Options:

    * `test?: true` - send as a specific inquiry instead of a control
    * `accept_interim?: true` - return an interim response instead of
      retrying
    * `factory?: true` - use the factory command set (request `0xff`)
  """
  @spec send_query(Device.t(), binary(), keyword()) :: {:ok, binary()} | error()
  def send_query(device, query, opts \\ []) do
    with :ok <- send_command(device, query, opts) do
      read_reply(device, opts)
    end
  end

  @doc "Send a query without reading the reply."
  @spec send_command(Device.t(), binary(), keyword()) :: :ok | error()
  def send_command(device, query, opts \\ []) do
    status =
      if Keyword.get(opts, :test?, false), do: @status_specific_inquiry, else: @status_control

    Device.send_command(device, <<status>> <> query,
      factory?: Keyword.get(opts, :factory?, false)
    )
  end

  @doc "Read and check a reply, retrying interim responses with backoff."
  @spec read_reply(Device.t(), keyword()) :: {:ok, binary()} | error()
  def read_reply(device, opts \\ []) do
    read_reply_attempt(
      device,
      Keyword.get(opts, :accept_interim?, false),
      Keyword.get(opts, :factory?, false),
      0
    )
  end

  defp read_reply_attempt(_device, _accept_interim?, _factory?, attempt)
       when attempt >= @max_interim_attempts do
    {:error, :interim_timeout}
  end

  defp read_reply_attempt(device, accept_interim?, factory?, attempt) do
    with {:ok, data} <- Device.read_reply(device, factory?: factory?) do
      case classify_reply(data) do
        {:interim, rest} when accept_interim? ->
          {:ok, rest}

        {:interim, _rest} ->
          Process.sleep(@interim_retry_ms * (Integer.pow(2, attempt) - 1))
          read_reply_attempt(device, accept_interim?, factory?, attempt + 1)

        other ->
          other
      end
    end
  end

  defp classify_reply(<<@status_not_implemented, _rest::binary>>),
    do: {:error, :not_implemented}

  defp classify_reply(<<@status_rejected, _rest::binary>> = data), do: {:error, {:rejected, data}}

  defp classify_reply(<<@status_interim, rest::binary>>), do: {:interim, rest}

  defp classify_reply(<<status, rest::binary>>)
       when status in [@status_accepted, @status_implemented],
       do: {:ok, rest}

  defp classify_reply(<<status, _rest::binary>>), do: {:error, {:unknown_status, status}}
  defp classify_reply(<<>>), do: {:error, :empty_reply}

  @doc """
  Open or close one of the device's descriptors. Errors are ignored, as
  in the reference.
  """
  @spec change_descriptor_state(
          Device.t(),
          descriptor :: atom(),
          action :: :open_read | :open_write | :close
        ) :: :ok
  def change_descriptor_state(device, descriptor, action) do
    descriptor = Map.fetch!(@descriptors, descriptor)
    action = Map.fetch!(@descriptor_actions, action)
    _ = send_query(device, Query.format("1808 #{descriptor} #{action} 00"))
    :ok
  end

  ## Session

  @doc "Take exclusive control of the device."
  @spec acquire(Device.t()) :: :ok | error()
  def acquire(device) do
    query = Query.format("ff 010c ffff ffff ffff ffff ffff ffff")

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "ff 010c ffff ffff ffff ffff ffff ffff") do
      :ok
    end
  end

  @doc "Release exclusive control of the device."
  @spec release(Device.t()) :: :ok | error()
  def release(device) do
    query = Query.format("ff 0100 ffff ffff ffff ffff ffff ffff")

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "ff 0100 ffff ffff ffff ffff ffff ffff") do
      :ok
    end
  end

  @doc """
  The device's NetMD level from its subunit identifier: `0x20` (network),
  `0x50` (program play) or `0x70` (editing).
  """
  @spec netmd_level(Device.t()) :: {:ok, byte()} | error()
  def netmd_level(device) do
    change_descriptor_state(device, :disc_subunit_identifier, :open_read)
    query = Query.format("1809 00 ff00 0000 0000")

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, values} <- Query.scan(reply, "1809 00 1000 %?%? %?%? %w %b %b %b %b %w %*") do
        [_descriptor_length, _generation, size_of_list_id, _, _, root_lists, buffer] = values
        parse_subunit_identifier(buffer, size_of_list_id, root_lists)
      end

    change_descriptor_state(device, :disc_subunit_identifier, :close)
    result
  end

  defp parse_subunit_identifier(buffer, size_of_list_id, root_lists) do
    skip = size_of_list_id * root_lists

    with <<_roots::binary-size(^skip), _dep_length::16, _fields_length::16, _attributes, _version,
           media_type_count, rest::binary>> <- buffer,
         {:ok, media_types} <- parse_media_types(rest, media_type_count, %{}) do
      case media_types do
        %{0x0301 => profile} -> {:ok, profile}
        _ -> {:error, :not_a_minidisc_recorder}
      end
    else
      _ -> {:error, :bad_subunit_identifier}
    end
  end

  defp parse_media_types(_rest, 0, acc), do: {:ok, acc}

  defp parse_media_types(
         <<media_type::16, profile_id, _attributes, _dep_length::16, _audio_version,
           _supports_md_clip, rest::binary>>,
         count,
         acc
       ) do
    parse_media_types(rest, count - 1, Map.put(acc, media_type, profile_id))
  end

  defp parse_media_types(_rest, _count, _acc), do: {:error, :bad_subunit_identifier}

  ## Status

  @doc "Raw status block."
  @spec status(Device.t()) :: {:ok, binary()} | error()
  def status(device) do
    change_descriptor_state(device, :operating_status_block, :open_read)
    query = Query.format("1809 8001 0230 8800 0030 8804 00 ff00 00000000")

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [value]} <-
             Query.scan(reply, "1809 8001 0230 8800 0030 8804 00 1000 00090000 %x") do
        {:ok, value}
      end

    change_descriptor_state(device, :operating_status_block, :close)
    result
  end

  @doc "Whether a disc is loaded."
  @spec disc_present?(Device.t()) :: {:ok, boolean()} | error()
  def disc_present?(device) do
    with {:ok, status} <- status(device) do
      case status do
        <<_::binary-size(4), 0x40, _::binary>> -> {:ok, true}
        _ -> {:ok, false}
      end
    end
  end

  @doc """
  Status mode and operating status number. Does not work on all devices.
  """
  @spec full_operating_status(Device.t()) ::
          {:ok, %{status_mode: byte(), operating_status: 0..0xFFFF}} | error()
  def full_operating_status(device) do
    change_descriptor_state(device, :operating_status_block, :open_read)
    query = Query.format("1809 8001 0330 8802 0030 8805 0030 8806 00 ff00 00000000")

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [status_mode, operating_status]} <-
             Query.scan(
               reply,
               "1809 8001 0330 8802 0030 8805 0030 8806 00 1000 00%?0000 00%b 8806 %x"
             ) do
        case operating_status do
          <<number::16, _::binary>> ->
            {:ok, %{status_mode: status_mode, operating_status: number}}

          _ ->
            {:error, :unparsable_operating_status}
        end
      end

    change_descriptor_state(device, :operating_status_block, :close)
    result
  end

  @doc "Operating status number, see `full_operating_status/1`."
  @spec operating_status(Device.t()) :: {:ok, 0..0xFFFF} | error()
  def operating_status(device) do
    with {:ok, %{operating_status: number}} <- full_operating_status(device) do
      {:ok, number}
    end
  end

  @doc "First playback status block."
  @spec playback_status1(Device.t()) :: {:ok, binary()} | error()
  def playback_status1(device), do: playback_status(device, 0x8801, 0x8807)

  @doc "Second playback status block."
  @spec playback_status2(Device.t()) :: {:ok, binary()} | error()
  def playback_status2(device), do: playback_status(device, 0x8802, 0x8806)

  defp playback_status(device, p1, p2) do
    change_descriptor_state(device, :operating_status_block, :open_read)
    query = Query.format("1809 8001 0330 %w 0030 8805 0030 %w 00 ff00 00000000", [p1, p2])

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [value]} <-
             Query.scan(
               reply,
               "1809 8001 0330 %?%? %?%? %?%? %?%? %?%? %? 1000 00%?0000 %x %?"
             ) do
        {:ok, value}
      end

    change_descriptor_state(device, :operating_status_block, :close)
    result
  end

  @doc """
  Current playback position: `{:ok, %{track: n, time: {hours, minutes,
  seconds, frames}}}`, or `{:ok, nil}` when the device rejects the query
  (no disc, for instance).
  """
  @spec position(Device.t()) ::
          {:ok, %{track: non_neg_integer(), time: {byte(), byte(), byte(), byte()}} | nil}
          | error()
  def position(device) do
    change_descriptor_state(device, :operating_status_block, :open_read)
    query = Query.format("1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 ff00 00000000")

    result =
      case send_query(device, query) do
        {:ok, reply} ->
          with {:ok, [track, hours, minutes, seconds, frames]} <-
                 Query.scan(
                   reply,
                   "1809 8001 0430 %?%? %?%? %?%? %?%? %?%? %?%? %?%? %? %?00 00%?0000 " <>
                     "000b 0002 0007 00 %w %B %B %B %B"
                 ) do
            {:ok, %{track: track, time: {hours, minutes, seconds, frames}}}
          end

        {:error, {:rejected, _}} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, reason}
      end

    change_descriptor_state(device, :operating_status_block, :close)
    result
  end

  ## Playback control

  @doc "Start playback."
  @spec play(Device.t()) :: :ok | error()
  def play(device), do: playback_action(device, :play)

  @doc "Pause playback."
  @spec pause(Device.t()) :: :ok | error()
  def pause(device), do: playback_action(device, :pause)

  @doc "Fast-forward."
  @spec fast_forward(Device.t()) :: :ok | error()
  def fast_forward(device), do: playback_action(device, :fast_forward)

  @doc "Rewind."
  @spec rewind(Device.t()) :: :ok | error()
  def rewind(device), do: playback_action(device, :rewind)

  defp playback_action(device, action) do
    query = Query.format("18c3 ff %b 000000", [Map.fetch!(@playback_actions, action)])

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "18c3 00 %b 000000") do
      :ok
    end
  end

  @doc "Stop playback. Errors are ignored, as in the reference (LAM-1 fix)."
  @spec stop(Device.t()) :: :ok
  def stop(device) do
    _ = send_query(device, Query.format("18c5 ff 00000000"))
    :ok
  end

  @doc "Eject the disc."
  @spec eject_disc(Device.t()) :: :ok | error()
  def eject_disc(device) do
    with {:ok, _reply} <- send_query(device, Query.format("18c1 ff 6000")) do
      :ok
    end
  end

  @doc "Whether the device supports ejecting by command."
  @spec can_eject_disc?(Device.t()) :: boolean()
  def can_eject_disc?(device) do
    match?({:ok, _}, send_query(device, Query.format("18c1 ff 6000"), test?: true))
  end

  @doc "Seek to the beginning of a track (zero-based)."
  @spec goto_track(Device.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | error()
  def goto_track(device, track) do
    query = Query.format("1850 ff010000 0000 %w", [track])

    with {:ok, reply} <- send_query(device, query),
         {:ok, [confirmed]} <- Query.scan(reply, "1850 00010000 0000 %w") do
      {:ok, confirmed}
    end
  end

  @doc "Seek to a position within a track."
  @spec goto_time(Device.t(), non_neg_integer(), keyword()) :: :ok | error()
  def goto_time(device, track, opts \\ []) do
    hour = Keyword.get(opts, :hour, 0)
    minute = Keyword.get(opts, :minute, 0)
    second = Keyword.get(opts, :second, 0)
    frame = Keyword.get(opts, :frame, 0)

    query = Query.format("1850 ff000000 0000 %w %B%B%B%B", [track, hour, minute, second, frame])

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1850 00000000 %?%? %w %B%B%B%B") do
      :ok
    end
  end

  @doc "Skip to the next track."
  @spec next_track(Device.t()) :: :ok | error()
  def next_track(device), do: track_change(device, :next)

  @doc "Skip to the previous track."
  @spec previous_track(Device.t()) :: :ok | error()
  def previous_track(device), do: track_change(device, :previous)

  @doc "Restart the current track."
  @spec restart_track(Device.t()) :: :ok | error()
  def restart_track(device), do: track_change(device, :restart)

  defp track_change(device, direction) do
    query = Query.format("1850 ff10 00000000 %w", [Map.fetch!(@track_movements, direction)])

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1850 0010 00000000 %?%?") do
      :ok
    end
  end

  ## Disc editing

  @doc "Erase the whole disc."
  @spec erase_disc(Device.t()) :: :ok | error()
  def erase_disc(device) do
    with {:ok, reply} <- send_query(device, Query.format("1840 ff 0000")),
         {:ok, _} <- Query.scan(reply, "1840 00 0000") do
      :ok
    end
  end

  @doc "Erase a track (zero-based)."
  @spec erase_track(Device.t(), non_neg_integer()) :: :ok | error()
  def erase_track(device, track) do
    query = Query.format("1840 ff01 00 201001 %w", [track])

    with {:ok, _reply} <- send_query(device, query) do
      :ok
    end
  end

  @doc "Move a track to another position (both zero-based)."
  @spec move_track(Device.t(), non_neg_integer(), non_neg_integer()) :: :ok | error()
  def move_track(device, source, dest) do
    query = Query.format("1843 ff00 00 201001 %w 201001 %w", [source, dest])

    with {:ok, _reply} <- send_query(device, query) do
      :ok
    end
  end

  ## Disc and track information

  @doc "Disc flags byte: `0x10` writable, `0x40` write-protected."
  @spec disc_flags(Device.t()) :: {:ok, byte()} | error()
  def disc_flags(device) do
    change_descriptor_state(device, :root_td, :open_read)
    query = Query.format("1806 01101000 ff00 0001000b")

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [flags]} <- Query.scan(reply, "1806 01101000 1000 0001000b %b") do
        {:ok, flags}
      end

    change_descriptor_state(device, :root_td, :close)
    result
  end

  @doc "Number of tracks on the disc."
  @spec track_count(Device.t()) :: {:ok, non_neg_integer()} | error()
  def track_count(device) do
    change_descriptor_state(device, :audio_contents_td, :open_read)
    query = Query.format("1806 02101001 3000 1000 ff00 00000000")

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [count]} <-
             Query.scan(reply, "1806 02101001 %?%? %?%? 1000 00%?0000 0006 0010000200%b") do
        {:ok, count}
      end

    change_descriptor_state(device, :audio_contents_td, :close)
    result
  end

  @doc """
  The raw disc title string, including group markup like `0;Title//`.
  """
  @spec raw_disc_title(Device.t(), keyword()) :: {:ok, String.t()} | error()
  def raw_disc_title(device, opts \\ []) do
    full_width? = Keyword.get(opts, :full_width?, false)
    wchar_value = if full_width?, do: 1, else: 0

    change_descriptor_state(device, :audio_contents_td, :open_read)
    change_descriptor_state(device, :disc_title_td, :open_read)

    result = read_title_chunks(device, wchar_value, 0, 0, 1, [])

    change_descriptor_state(device, :disc_title_td, :close)
    change_descriptor_state(device, :audio_contents_td, :close)
    result
  end

  defp read_title_chunks(_device, _wchar, done, _remaining, total, acc) when done >= total do
    {:ok, acc |> Enum.reverse() |> Enum.join()}
  end

  defp read_title_chunks(device, wchar, done, remaining, total, acc) do
    query = Query.format("1806 02201801 00%b 3000 0a00 ff00 %w%w", [wchar, remaining, done])

    with {:ok, reply} <- send_query(device, query),
         {:ok, chunk_size, total, chunk} <- parse_title_chunk(reply, remaining, total) do
      done = done + chunk_size
      read_title_chunks(device, wchar, done, total - done, total, [SJIS.decode(chunk) | acc])
    end
  end

  # The first chunk carries the total length and a 6-byte header.
  defp parse_title_chunk(reply, 0, _total) do
    with {:ok, [chunk_size, total, chunk]} <-
           Query.scan(reply, "1806 02201801 00%? 3000 0a00 1000 %w0000 %?%?000a %w %*") do
      {:ok, chunk_size - 6, total, chunk}
    end
  end

  defp parse_title_chunk(reply, _remaining, total) do
    with {:ok, [chunk_size, chunk]} <-
           Query.scan(reply, "1806 02201801 00%? 3000 0a00 1000 %w%?%? %*") do
      {:ok, chunk_size, total, chunk}
    end
  end

  @doc """
  The disc title with group markup stripped.
  """
  @spec disc_title(Device.t(), keyword()) :: {:ok, String.t()} | error()
  def disc_title(device, opts \\ []) do
    full_width? = Keyword.get(opts, :full_width?, false)

    with {:ok, title} <- raw_disc_title(device, opts) do
      {:ok, strip_group_markup(title, full_width?)}
    end
  end

  defp strip_group_markup(title, full_width?) do
    delimiter = if full_width?, do: "／／", else: "//"
    title_marker = if full_width?, do: "０；", else: "0;"
    first_entry = title |> String.split(delimiter) |> hd()

    cond do
      not String.ends_with?(title, delimiter) -> title
      String.starts_with?(first_entry, title_marker) -> String.slice(first_entry, 2..-1//1)
      true -> ""
    end
  end

  @doc """
  Groups on the disc as `{name, full_width_name, tracks}` tuples, with
  `nil` names for the ungrouped tracks entry. Track numbers zero-based.
  """
  @spec track_group_list(Device.t()) ::
          {:ok, [{String.t() | nil, String.t() | nil, [non_neg_integer()]}]} | error()
  def track_group_list(device) do
    with {:ok, raw_title} <- raw_disc_title(device),
         {:ok, track_count} <- track_count(device),
         {:ok, raw_full_width} <- raw_disc_title(device, full_width?: true) do
      parse_groups(raw_title, raw_full_width, track_count)
    end
  end

  defp parse_groups(raw_title, raw_full_width, track_count) do
    groups = String.split(raw_title, "//")
    full_width_groups = String.split(raw_full_width, "／／")

    with {:ok, result, grouped} <-
           collect_groups(groups, raw_title, full_width_groups, track_count) do
      ungrouped = Enum.reject(0..(track_count - 1)//1, &MapSet.member?(grouped, &1))

      case ungrouped do
        [] -> {:ok, result}
        tracks -> {:ok, [{nil, nil, tracks} | result]}
      end
    end
  end

  defp collect_groups(groups, raw_title, full_width_groups, track_count) do
    Enum.reduce_while(groups, {:ok, [], MapSet.new()}, fn group, {:ok, acc, grouped} ->
      case parse_group(group, raw_title, full_width_groups, track_count, grouped) do
        :skip -> {:cont, {:ok, acc, grouped}}
        {:ok, entry, grouped} -> {:cont, {:ok, acc ++ [entry], grouped}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc, grouped} -> {:ok, acc, grouped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_group(group, raw_title, full_width_groups, track_count, grouped) do
    [track_range | _] = String.split(group, ";", parts: 2)

    if skip_group?(group, raw_title) or track_range == "" do
      :skip
    else
      build_group(group, track_range, full_width_groups, track_count, grouped)
    end
  end

  defp skip_group?(group, raw_title) do
    group == "" or String.starts_with?(group, "0;") or not String.contains?(group, ";") or
      not String.contains?(raw_title, "//")
  end

  defp build_group(group, track_range, full_width_groups, track_count, grouped) do
    group_name = String.slice(group, (String.length(track_range) + 1)..-1//1)
    full_width_name = find_full_width_name(full_width_groups, track_range)

    with {:ok, track_min, track_max} <- parse_range(track_range),
         :ok <- validate_range(track_min, min(track_max, track_count), track_range) do
      tracks = Enum.to_list((track_min - 1)..(min(track_max, track_count) - 1)//1)
      claim_tracks(tracks, group_name, full_width_name, grouped)
    end
  end

  defp find_full_width_name(full_width_groups, track_range) do
    full_width_range = Titles.half_width_to_full_width_range(track_range)

    Enum.find_value(full_width_groups, fn candidate ->
      if full_width_range != "" and String.starts_with?(candidate, full_width_range) do
        String.slice(candidate, (String.length(full_width_range) + 1)..-1//1)
      end
    end)
  end

  defp validate_range(track_min, track_max, track_range)
       when track_min < 0 or track_min > track_max,
       do: {:error, {:bad_group_range, track_range}}

  defp validate_range(_track_min, _track_max, _track_range), do: :ok

  defp claim_tracks(tracks, group_name, full_width_name, grouped) do
    case Enum.find(tracks, &MapSet.member?(grouped, &1)) do
      nil ->
        grouped = Enum.reduce(tracks, grouped, &MapSet.put(&2, &1))
        {:ok, {group_name, full_width_name, tracks}, grouped}

      track ->
        {:error, {:track_in_two_groups, track}}
    end
  end

  defp parse_range(track_range) do
    {min_string, max_string} =
      case String.split(track_range, "-", parts: 2) do
        [single] -> {single, single}
        [min, max] -> {min, max}
      end

    with {track_min, _} <- Integer.parse(min_string),
         {track_max, _} <- Integer.parse(max_string) do
      {:ok, track_min, track_max}
    else
      :error -> {:error, {:bad_group_range, track_range}}
    end
  end

  @doc "Title of a track (zero-based)."
  @spec track_title(Device.t(), non_neg_integer(), keyword()) :: {:ok, String.t()} | error()
  def track_title(device, track, opts \\ []) do
    full_width? = Keyword.get(opts, :full_width?, false)
    wchar_value = if full_width?, do: 3, else: 2
    descriptor = if full_width?, do: :audio_utoc4_td, else: :audio_utoc1_td

    change_descriptor_state(device, descriptor, :open_read)
    query = Query.format("1806 022018%b %w 3000 0a00 ff00 00000000", [wchar_value, track])

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [title]} <-
             Query.scan(reply, "1806 022018%? %?%? %?%? %?%? 1000 00%?0000 00%?000a %x") do
        {:ok, SJIS.decode(title)}
      end

    change_descriptor_state(device, descriptor, :close)
    result
  end

  @doc """
  Set the raw disc title. The title is sanitized; group markup must
  already be in place (see `Netmd.Commands.rename_disc/3` for the
  friendly version).
  """
  @spec set_disc_title(Device.t(), String.t(), keyword()) :: :ok | error()
  def set_disc_title(device, title, opts \\ []) do
    full_width? = Keyword.get(opts, :full_width?, false)
    wchar_value = if full_width?, do: 1, else: 0
    sharp? = device.vendor_id == 0x04DD

    with {:ok, current_title} <- raw_disc_title(device, opts) do
      if current_title == title do
        # Setting the same title causes problems with the LAM.
        :ok
      else
        write_disc_title(device, title, current_title, wchar_value, full_width?, sharp?)
      end
    end
  end

  defp write_disc_title(device, title, current_title, wchar_value, full_width?, sharp?) do
    old_length = SJIS.encoded_length(current_title)
    # The reference measures the length before sanitizing.
    new_length = SJIS.encoded_length(title)

    title =
      if full_width?,
        do: Titles.sanitize_full_width(title),
        else: Titles.sanitize_half_width(title)

    if sharp? do
      # Sharp disc rename (issue 67 of webminidisc)
      change_descriptor_state(device, :audio_utoc1_td, :open_write)
    else
      change_descriptor_state(device, :disc_title_td, :close)
      change_descriptor_state(device, :disc_title_td, :open_write)
    end

    query =
      Query.format("1807 02201801 00%b 3000 0a00 5000 %w 0000 %w %*", [
        wchar_value,
        new_length,
        old_length,
        SJIS.encode(title)
      ])

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, _} <- Query.scan(reply, "1807 02201801 00%? 3000 0a00 5000 %?%? 0000 %?%?") do
        :ok
      end

    if sharp? do
      change_descriptor_state(device, :audio_utoc1_td, :close)
    else
      change_descriptor_state(device, :disc_title_td, :close)
      change_descriptor_state(device, :disc_title_td, :open_read)
      change_descriptor_state(device, :disc_title_td, :close)
    end

    result
  end

  @doc "Set the title of a track (zero-based). The title is sanitized."
  @spec set_track_title(Device.t(), non_neg_integer(), String.t(), keyword()) :: :ok | error()
  def set_track_title(device, track, title, opts \\ []) do
    full_width? = Keyword.get(opts, :full_width?, false)
    wchar_value = if full_width?, do: 3, else: 2
    descriptor = if full_width?, do: :audio_utoc4_td, else: :audio_utoc1_td

    title =
      if full_width?,
        do: Titles.sanitize_full_width(title),
        else: Titles.sanitize_half_width(title)

    new_length = SJIS.encoded_length(title)

    with {:ok, current} <- current_track_title(device, track, opts) do
      if current == title do
        :ok
      else
        old_length = old_title_length(current)
        write_track_title(device, track, title, wchar_value, new_length, old_length, descriptor)
      end
    end
  end

  # An unset title was rejected on read; its old length is zero.
  defp old_title_length(nil), do: 0
  defp old_title_length(current), do: SJIS.encoded_length(current)

  defp write_track_title(device, track, title, wchar_value, new_length, old_length, descriptor) do
    change_descriptor_state(device, descriptor, :open_write)

    query =
      Query.format("1807 022018%b %w 3000 0a00 5000 %w 0000 %w %*", [
        wchar_value,
        track,
        new_length,
        old_length,
        SJIS.encode(title)
      ])

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, _} <- Query.scan(reply, "1807 022018%? %?%? 3000 0a00 5000 %?%? 0000 %?%?") do
        :ok
      end

    change_descriptor_state(device, descriptor, :close)
    result
  end

  defp current_track_title(device, track, opts) do
    case track_title(device, track, opts) do
      {:ok, title} -> {:ok, title}
      # An unset title is rejected; treated as empty (old length 0).
      {:error, {:rejected, _}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp track_info(device, track, p1, p2) do
    change_descriptor_state(device, :audio_contents_td, :open_read)
    query = Query.format("1806 02201001 %w %w %w ff00 00000000", [track, p1, p2])

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [value]} <- Query.scan(reply, "1806 02201001 %?%? %?%? %?%? 1000 00%?0000 %x") do
        {:ok, value}
      end

    change_descriptor_state(device, :audio_contents_td, :close)
    result
  end

  @doc "Track length as `{hours, minutes, seconds, frames}` (zero-based track)."
  @spec track_length(Device.t(), non_neg_integer()) ::
          {:ok, {byte(), byte(), byte(), byte()}} | error()
  def track_length(device, track) do
    with {:ok, raw} <- track_info(device, track, 0x3000, 0x0100),
         {:ok, [hours, minutes, seconds, frames]} <-
           Query.scan(raw, "0001 0006 0000 %B %B %B %B") do
      {:ok, {hours, minutes, seconds, frames}}
    end
  end

  @doc """
  Track codec and channel bytes: codec `0x90` SP, `0x92` LP2, `0x93` LP4;
  channel `0x00` stereo, `0x01` mono.
  """
  @spec track_encoding(Device.t(), non_neg_integer()) ::
          {:ok, {codec :: byte(), channel :: byte()}} | error()
  def track_encoding(device, track) do
    with {:ok, raw} <- track_info(device, track, 0x3080, 0x0700),
         {:ok, [codec, channel]} <- Query.scan(raw, "8007 0004 0110 %b %b") do
      {:ok, {codec, channel}}
    end
  end

  @doc "Track flags byte: `0x03` protected, `0x00` unprotected (zero-based)."
  @spec track_flags(Device.t(), non_neg_integer()) :: {:ok, byte()} | error()
  def track_flags(device, track) do
    change_descriptor_state(device, :audio_contents_td, :open_read)
    query = Query.format("1806 01201001 %w ff00 00010008", [track])

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [flags]} <- Query.scan(reply, "1806 01201001 %?%? 10 00 00010008 %b") do
        {:ok, flags}
      end

    change_descriptor_state(device, :audio_contents_td, :close)
    result
  end

  @doc """
  Disc capacity as three `{hours, minutes, seconds, frames}` tuples:
  recorded, total and available.
  """
  @spec disc_capacity(Device.t()) ::
          {:ok, [{non_neg_integer(), byte(), byte(), byte()}]} | error()
  def disc_capacity(device) do
    change_descriptor_state(device, :root_td, :open_read)
    query = Query.format("1806 02101000 3080 0300 ff00 00000000")

    result =
      with {:ok, reply} <- send_query(device, query),
           # 8003 is %?03 because Panasonic returns 0803; meaning unknown.
           {:ok, values} <-
             Query.scan(
               reply,
               "1806 02101000 3080 0300 1000 001d0000 001b %?03 0017 8000 " <>
                 "0005 %W %B %B %B 0005 %W %B %B %B 0005 %W %B %B %B"
             ) do
        {:ok, values |> Enum.chunk_every(4) |> Enum.map(&List.to_tuple/1)}
      end

    change_descriptor_state(device, :root_td, :close)
    result
  end

  @doc "Recording parameters: `{encoding, channel}` bytes for the current mode."
  @spec recording_parameters(Device.t()) :: {:ok, {byte(), byte()}} | error()
  def recording_parameters(device) do
    change_descriptor_state(device, :operating_status_block, :open_read)
    query = Query.format("1809 8001 0330 8801 0030 8805 0030 8807 00 ff00 00000000")

    result =
      with {:ok, reply} <- send_query(device, query),
           {:ok, [encoding, channel]} <-
             Query.scan(
               reply,
               "1809 8001 0330 8801 0030 8805 0030 8807 00 1000 000e0000 " <>
                 "000c 8805 0008 80e0 0110 %b %b 4000"
             ) do
        {:ok, {encoding, channel}}
      end

    change_descriptor_state(device, :operating_status_block, :close)
    result
  end

  ## Track upload (MZ-RH1 only)

  @doc """
  Read a track's raw audio data off the disc. Only the MZ-RH1 (and M200)
  supports this. Returns the disc format byte, frame count and data.

  Options are passed through to `Netmd.Device.read_bulk/3` (`:chunk_size`,
  `:progress`, `:timeout`).
  """
  @spec save_track_to_binary(Device.t(), non_neg_integer(), keyword()) ::
          {:ok, %{format: byte(), frames: non_neg_integer(), data: binary()}} | error()
  def save_track_to_binary(device, track, opts \\ []) do
    query = Query.format("1800 080046 f003010330 ff00 1001 %w", [track + 1])

    with {:ok, reply} <- send_query(device, query, accept_interim?: true),
         {:ok, [frames, codec, length]} <-
           Query.scan(reply, "1800 080046 f0030103 300000 1001 %w %b %d"),
         {:ok, data} <- Device.read_bulk(device, length, opts),
         {:ok, confirmation} <- read_reply(device),
         {:ok, _} <-
           Query.scan(confirmation, "1800 080046 f003010330 0000 1001 %?%? %?%?") do
      Process.sleep(500)
      # The low three bits of the codec byte carry the disc format.
      <<_::5, format_high::2, _::1>> = <<codec>>
      {:ok, %{format: format_high * 2, frames: frames, data: data}}
    end
  end

  @doc "Enable or disable protection on newly recorded tracks."
  @spec disable_new_track_protection(Device.t(), 0..0xFFFF) :: :ok | error()
  def disable_new_track_protection(device, value) do
    query = Query.format("1800 080046 f0030103 2b ff %w", [value])

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 2b 00 %?%?") do
      :ok
    end
  end

  ## Secure session

  @doc "Enter the secure session used for track download."
  @spec enter_secure_session(Device.t()) :: :ok | error()
  def enter_secure_session(device) do
    query = Query.format("1800 080046 f0030103 80 ff")

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 80 00") do
      :ok
    end
  end

  @doc "Leave the secure session."
  @spec leave_secure_session(Device.t()) :: :ok | error()
  def leave_secure_session(device) do
    query = Query.format("1800 080046 f0030103 81 ff")

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 81 00") do
      :ok
    end
  end

  @doc "Switch a Hi-MD capable device to Hi-MD mode."
  @spec enter_himd_mode(Device.t()) :: :ok | error()
  def enter_himd_mode(device) do
    query = Query.format("1800 080046 f0030104 82 ff")

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030104 82 00") do
      :ok
    end
  end

  @doc "The device's DRM leaf ID."
  @spec leaf_id(Device.t()) :: {:ok, binary()} | error()
  def leaf_id(device) do
    query = Query.format("1800 080046 f0030103 11 ff")

    with {:ok, reply} <- send_query(device, query),
         {:ok, [id]} <- Query.scan(reply, "1800 080046 f0030103 11 00 %*") do
      {:ok, id}
    end
  end

  @doc "Send an enabling key block to the device."
  @spec send_key_data(Device.t(), EKB.t()) :: :ok | error()
  def send_key_data(device, %EKB{} = ekb) do
    chain_length = length(ekb.chain)
    databytes = 16 + 16 * chain_length + 24

    query =
      Query.format("1800 080046 f0030103 12 ff %w 0000 %w %d %d %d 00000000 %* %*", [
        databytes,
        databytes,
        chain_length,
        ekb.depth,
        ekb.id,
        IO.iodata_to_binary(ekb.chain),
        ekb.signature
      ])

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 12 01 %?%? %?%?%?%?") do
      :ok
    end
  end

  @doc "Exchange nonces with the device; returns the device nonce."
  @spec session_key_exchange(Device.t(), host_nonce :: <<_::64>>) :: {:ok, binary()} | error()
  def session_key_exchange(device, host_nonce) when byte_size(host_nonce) == 8 do
    query = Query.format("1800 080046 f0030103 20 ff 000000 %*", [host_nonce])

    with {:ok, reply} <- send_query(device, query),
         # 20 %? instead of 20 00: fix for the Panasonic SJ-MR270
         {:ok, [device_nonce]} <- Query.scan(reply, "1800 080046 f0030103 20 %? 000000 %#") do
      {:ok, device_nonce}
    end
  end

  @doc "Make the device forget the negotiated session key."
  @spec session_key_forget(Device.t()) :: :ok | error()
  def session_key_forget(device) do
    query = Query.format("1800 080046 f0030103 21 ff 000000")

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 21 00 000000") do
      :ok
    end
  end

  @doc """
  Announce a track download, passing the content ID and key encryption
  key encrypted with the 8-byte session key.
  """
  @spec setup_download(
          Device.t(),
          content_id :: <<_::160>>,
          key_encryption_key :: <<_::64>>,
          session_key :: <<_::64>>
        ) :: :ok | error()
  def setup_download(device, content_id, key_encryption_key, session_key)
      when byte_size(content_id) == 20 and byte_size(key_encryption_key) == 8 and
             byte_size(session_key) == 8 do
    message = <<1, 1, 1, 1>> <> content_id <> key_encryption_key
    encrypted = Crypto.des_cbc_encrypt(session_key, @zero_iv, message)
    query = Query.format("1800 080046 f0030103 22 ff 0000 %*", [encrypted])

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 22 00 0000") do
      :ok
    end
  end

  @doc "Commit a downloaded track (zero-based), proving session knowledge."
  @spec commit_track(Device.t(), non_neg_integer(), session_key :: <<_::64>>) :: :ok | error()
  def commit_track(device, track, session_key) when byte_size(session_key) == 8 do
    authentication = Crypto.des_ecb_encrypt(session_key, @zero_iv)
    query = Query.format("1800 080046 f0030103 48 ff 00 1001 %w %*", [track, authentication])

    with {:ok, reply} <- send_query(device, query),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 48 00 00 1001 %?%?") do
      :ok
    end
  end

  @doc """
  Stream encrypted track packets to the device.

  `packets` is an enumerable of `{key, iv, data}` tuples as produced by
  `Netmd.Track.packets/1`. Returns the new track number and the
  decrypted UUID and content ID the device reports.

  Options:

    * `:progress` - function called with `(total_bytes, written_bytes)`
    * `:settle_ms` - wait before and after announcing (default 200, the
      reference's allowance for slow Sharp devices)
  """
  @spec send_track(
          Device.t(),
          wireformat :: byte(),
          discformat :: byte(),
          frames :: pos_integer(),
          packet_size :: pos_integer(),
          packets :: Enumerable.t(),
          session_key :: <<_::64>>,
          keyword()
        ) ::
          {:ok, %{track: non_neg_integer(), uuid: binary(), ccid: binary()}} | error()
  def send_track(
        device,
        wireformat,
        discformat,
        frames,
        packet_size,
        packets,
        session_key,
        opts \\ []
      ) do
    settle_ms = Keyword.get(opts, :settle_ms, 200)
    progress = Keyword.get(opts, :progress)
    total_bytes = packet_size + 24

    Process.sleep(settle_ms)

    query =
      Query.format("1800 080046 f0030103 28 ff 000100 1001 ffff 00 %b %b %d %d", [
        wireformat,
        discformat,
        frames,
        total_bytes
      ])

    with {:ok, reply} <- send_query(device, query, accept_interim?: true),
         {:ok, _} <- Query.scan(reply, "1800 080046 f0030103 28 00 000100 1001 %?%? 00 %*") do
      Process.sleep(settle_ms)

      with :ok <- write_packets(device, packets, packet_size, total_bytes, progress),
           {:ok, final} <- read_reply(device),
           {:ok, _pending} <- Device.reply_length(device),
           {:ok, [track, encrypted]} <-
             Query.scan(
               final,
               "1800 080046 f0030103 28 00 000100 1001 %w 00 %?%? %?%?%?%? %?%?%?%? %*"
             ) do
        decrypt_track_confirmation(track, encrypted, session_key)
      end
    end
  end

  defp decrypt_track_confirmation(track, encrypted, session_key)
       when byte_size(encrypted) >= 32 do
    decrypted = Crypto.des_cbc_decrypt(session_key, @zero_iv, encrypted)

    {:ok,
     %{
       track: track,
       uuid: binary_part(decrypted, 0, 8),
       ccid: binary_part(decrypted, 12, 20)
     }}
  end

  defp decrypt_track_confirmation(_track, _encrypted, _session_key),
    do: {:error, :bad_track_confirmation}

  defp write_packets(device, packets, packet_size, total_bytes, progress) do
    packets
    |> Enum.reduce_while({:ok, 0, 0}, fn {key, iv, data}, {:ok, index, written} ->
      if progress, do: progress.(total_bytes, written)

      binpack =
        case index do
          0 -> <<0, 0, 0, 0, packet_size::little-32, key::binary, iv::binary, data::binary>>
          _later -> data
        end

      case Device.write_bulk(device, binpack) do
        :ok -> {:cont, {:ok, index + 1, written + byte_size(data)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _count, written} ->
        if progress, do: progress.(total_bytes, written)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "UUID of a track (zero-based) as raw bytes."
  @spec track_uuid(Device.t(), non_neg_integer()) :: {:ok, binary()} | error()
  def track_uuid(device, track) do
    query = Query.format("1800 080046 f0030103 23 ff 1001 %w", [track])

    with {:ok, reply} <- send_query(device, query),
         {:ok, [uuid]} <- Query.scan(reply, "1800 080046 f0030103 23 00 1001 %?%? %*") do
      {:ok, uuid}
    end
  end

  @doc "Terminate the secure session state machine."
  @spec terminate(Device.t()) :: :ok | error()
  def terminate(device) do
    with {:ok, _reply} <- send_query(device, Query.format("1800 080046 f0030103 2a ff00")) do
      :ok
    end
  end
end
