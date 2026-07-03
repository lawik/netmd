defmodule Netmd.Commands do
  @moduledoc """
  High-level operations composed from `Netmd.Interface` commands, ported
  from netmd-js's netmd-commands.

  Divergence from the reference: the title-space estimation
  (`remaining_characters_for_titles/2` and friends) computes group ranges
  cleanly where the reference's JavaScript accidentally splices `"false"`
  and `"null"` strings into its worst-case length estimates.
  """

  alias Netmd.Audio
  alias Netmd.Device
  alias Netmd.Disc
  alias Netmd.Interface
  alias Netmd.Session
  alias Netmd.Titles
  alias Netmd.Track

  @type error :: Interface.error()

  @encodings %{0x90 => :sp, 0x92 => :lp2, 0x93 => :lp4}
  @channels %{0x00 => :stereo, 0x01 => :mono}
  @protections %{0x00 => :unprotected, 0x03 => :protected}

  @operating_statuses %{
    50_687 => :ready,
    50_037 => :playing,
    50_045 => :paused,
    49_983 => :fast_forward,
    49_999 => :rewind,
    65_315 => :reading_toc,
    65_296 => :no_disc,
    65_535 => :disc_blank,
    65_319 => :ready_for_transfer
  }

  # A disc TOC has 255 title cells of 7 characters each.
  @cell_limit 255
  @cell_size 7

  @doc """
  Convert an `{hours, minutes, seconds, frames}` tuple to frames
  (512 per second).
  """
  @spec time_to_frames({integer(), integer(), integer(), integer()}) :: integer()
  def time_to_frames({hours, minutes, seconds, frames}) do
    ((hours * 60 + minutes) * 60 + seconds) * 512 + frames
  end

  @doc """
  Current device state: disc presence, operating state, track and time.
  """
  @spec device_status(Device.t()) ::
          {:ok,
           %{
             disc_present: boolean(),
             state: atom(),
             track: non_neg_integer() | nil,
             time: %{minute: integer(), second: integer(), frame: integer()} | nil
           }}
          | error()
  def device_status(device) do
    with {:ok, status} <- Interface.status(device),
         {:ok, playback} <- Interface.playback_status2(device),
         {:ok, position} <- Interface.position(device) do
      disc_present = not match?(<<_::binary-size(4), 0x80, _::binary>>, status)

      operating =
        case playback do
          <<_::binary-size(4), high, low, _::binary>> -> high * 256 + low
          _ -> 0
        end

      state = Map.get(@operating_statuses, operating, :unknown)
      state = if state == :playing and not disc_present, do: :ready, else: state

      {track, time} =
        case position do
          %{track: track, time: {hours, minutes, seconds, frames}} ->
            {track, %{minute: hours * 60 + minutes, second: seconds, frame: frames}}

          nil ->
            {nil, nil}
        end

      {:ok,
       %{
         disc_present: disc_present and state not in [:reading_toc, :no_disc],
         state: state,
         track: track,
         time: time
       }}
    end
  end

  @doc """
  Full disc listing: title, capacity, groups and per-track details.
  """
  @spec list_content(Device.t()) :: {:ok, Disc.t()} | error()
  def list_content(device) do
    with {:ok, flags} <- Interface.disc_flags(device),
         {:ok, title} <- Interface.disc_title(device),
         {:ok, full_width_title} <- Interface.disc_title(device, full_width?: true),
         {:ok, [used, total, left]} <- Interface.disc_capacity(device),
         {:ok, track_count} <- Interface.track_count(device),
         {:ok, group_list} <- Interface.track_group_list(device),
         {:ok, groups} <- build_groups(device, group_list) do
      {frames_used, frames_total, frames_left} =
        normalize_capacity(time_to_frames(used), time_to_frames(total), time_to_frames(left))

      <<_::3, write_protected::1, _::1, writable::1, _::2>> = <<flags>>

      {:ok,
       %Disc{
         title: title,
         full_width_title: full_width_title,
         writable: writable == 1,
         write_protected: write_protected == 1,
         used: frames_used,
         left: frames_left,
         total: frames_total,
         track_count: track_count,
         groups: groups
       }}
    end
  end

  # Some devices report the time remaining of the currently selected
  # recording mode (Sharps); scale back to SP time.
  defp normalize_capacity(used, total, left) when total > 512 * 60 * 82,
    do: normalize_capacity(div(used, 2), div(total, 2), div(left, 2))

  defp normalize_capacity(used, total, left), do: {used, total, left}

  defp build_groups(device, group_list) do
    group_list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{title, full_width_title, track_numbers}, index},
                                       {:ok, acc} ->
      case build_tracks(device, track_numbers) do
        {:ok, tracks} ->
          group = %Disc.Group{
            index: index,
            title: title,
            full_width_title: full_width_title,
            tracks: tracks
          }

          {:cont, {:ok, acc ++ [group]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp build_tracks(device, track_numbers) do
    Enum.reduce_while(track_numbers, {:ok, []}, fn track, {:ok, acc} ->
      case build_track(device, track) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_track(device, track) do
    with {:ok, {codec, channel}} <- Interface.track_encoding(device, track),
         {:ok, duration} <- Interface.track_length(device, track),
         {:ok, flags} <- Interface.track_flags(device, track),
         {:ok, title} <- Interface.track_title(device, track),
         {:ok, full_width_title} <- Interface.track_title(device, track, full_width?: true) do
      {:ok,
       %Disc.Track{
         index: track,
         title: title,
         full_width_title: full_width_title,
         duration: time_to_frames(duration),
         channel: Map.get(@channels, channel, channel),
         encoding: Map.get(@encodings, codec, codec),
         protection: Map.get(@protections, flags, flags)
       }}
    end
  end

  ## Title space accounting

  @doc """
  TOC cells needed for a track's titles, as `{half_width, full_width}`.
  """
  @spec cells_for_title(Disc.Track.t()) :: {non_neg_integer(), non_neg_integer()}
  def cells_for_title(%Disc.Track{} = track) do
    # Non-SP tracks may get an 'LP: ' prefix even for empty titles.
    correction = if track.encoding == :sp, do: 0, else: 1

    full_width = chars_to_cells(String.length(track.full_width_title || "") * 2)
    half_width = chars_to_cells(Titles.half_width_length(track.title || ""))

    {max(correction, half_width), max(correction, full_width)}
  end

  @doc """
  Characters still available for titling, as `{half_width, full_width}`.
  """
  @spec remaining_characters_for_titles(Disc.t(), keyword()) ::
          {non_neg_integer(), non_neg_integer()}
  def remaining_characters_for_titles(%Disc{} = disc, opts \\ []) do
    include_groups? = Keyword.get(opts, :include_groups?, true)

    groups = Enum.filter(disc.groups, &(&1.title != nil))

    # Worst case: the disc title also carries the `0;` marker and `//`.
    {half_title, full_title} =
      if include_groups? do
        Enum.reduce(groups, {disc.title <> "0;//", disc.full_width_title <> "0;//"}, fn group,
                                                                                        {half,
                                                                                         full} ->
          range = group_range_estimate(group)
          {half <> (group.title || "") <> range, full <> (group.full_width_title || "") <> range}
        end)
      else
        {disc.title <> "0;//", disc.full_width_title <> "0;//"}
      end

    used_half =
      chars_to_cells(Titles.half_width_length(half_title)) +
        Enum.sum(Enum.map(Disc.tracks(disc), &elem(cells_for_title(&1), 0)))

    used_full =
      chars_to_cells(String.length(full_title) * 2) +
        Enum.sum(Enum.map(Disc.tracks(disc), &elem(cells_for_title(&1), 1)))

    {max(@cell_limit - used_half, 0) * @cell_size, max(@cell_limit - used_full, 0) * @cell_size}
  end

  defp group_range_estimate(%Disc.Group{tracks: tracks}) do
    indices = Enum.map(tracks, & &1.index)
    min_index = Enum.min(indices, fn -> 0 end)
    max_index = Enum.max(indices, fn -> 0 end)

    case tracks do
      [_single] -> "#{min_index + 1}//"
      _many -> "#{min_index + 1}-#{max_index + 1}//"
    end
  end

  @doc """
  Compile raw disc title strings with group markup from a `Netmd.Disc`,
  fitting as many groups as the TOC allows.
  """
  @spec compile_disc_titles(Disc.t()) :: {String.t(), String.t()}
  def compile_disc_titles(%Disc{} = disc) do
    {available_half, available_full} =
      remaining_characters_for_titles(
        %Disc{disc | title: "", full_width_title: ""},
        include_groups?: false
      )

    use_full_width? = use_full_width?(disc)
    real_groups = Enum.filter(disc.groups, &(&1.title != nil and &1.tracks != []))

    {half, full} =
      compile_group_markup(disc, real_groups, use_full_width?, available_half, available_full)

    half = if fits_half?(half, available_half), do: half, else: ""
    full = if chars_to_cells(String.length(full) * 2) <= available_full, do: full, else: ""

    {half, if(use_full_width?, do: full, else: "")}
  end

  defp use_full_width?(disc) do
    disc.full_width_title != "" or
      Enum.any?(disc.groups, &(&1.full_width_title not in [nil, ""])) or
      Enum.any?(Disc.tracks(disc), &(&1.full_width_title not in [nil, ""]))
  end

  # With no real groups, the plain titles are used as-is.
  defp compile_group_markup(disc, [], _use_full_width?, _available_half, _available_full),
    do: {disc.title, disc.full_width_title}

  defp compile_group_markup(disc, real_groups, use_full_width?, available_half, available_full) do
    initial_half = if disc.title != "", do: "0;#{disc.title}//", else: ""
    initial_full = if use_full_width?, do: "０；#{disc.full_width_title}／／", else: ""

    Enum.reduce(real_groups, {initial_half, initial_full}, fn group, {half, full} ->
      {half_candidate, full_candidate} = group_candidates(group, half, full)

      {
        if(fits_half?(half_candidate, available_half), do: half_candidate, else: half),
        if(use_full_width? and fits_full?(full_candidate, available_full),
          do: full_candidate,
          else: full
        )
      }
    end)
  end

  defp group_candidates(group, half, full) do
    range = compile_range(group)

    {
      half <> "#{range};#{group.title}//",
      full <>
        Titles.half_width_to_full_width_range(range) <>
        "；#{group.full_width_title || ""}／／"
    }
  end

  defp compile_range(%Disc.Group{tracks: tracks}) do
    min_index = tracks |> Enum.map(& &1.index) |> Enum.min()

    case tracks do
      [_single] -> "#{min_index + 1}"
      _many -> "#{min_index + 1}-#{min_index + length(tracks)}"
    end
  end

  defp fits_half?(title, available),
    do: available - chars_to_cells(Titles.half_width_length(title)) * @cell_size >= 0

  defp fits_full?(title, available),
    do: available - chars_to_cells(String.length(title) * 2) * @cell_size >= 0

  defp chars_to_cells(length), do: div(length + @cell_size - 1, @cell_size)

  @doc """
  Write a disc's group structure back to the TOC.
  """
  @spec rewrite_disc_groups(Device.t(), Disc.t()) :: :ok | error()
  def rewrite_disc_groups(device, %Disc{} = disc) do
    {half, full} = compile_disc_titles(disc)

    with :ok <- Interface.set_disc_title(device, half) do
      Interface.set_disc_title(device, full, full_width?: true)
    end
  end

  @doc """
  Rename the disc, preserving any group markup in the raw title.

  Accepts `full_width_title:` to also set the full-width title.
  """
  @spec rename_disc(Device.t(), String.t(), keyword()) :: :ok | error()
  def rename_disc(device, new_name, opts \\ []) do
    new_name = Titles.sanitize_half_width(new_name)

    new_full_width =
      case Keyword.fetch(opts, :full_width_title) do
        {:ok, title} -> Titles.sanitize_full_width(title)
        :error -> nil
      end

    with {:ok, old_name} <- Interface.disc_title(device),
         {:ok, old_full_width} <- Interface.disc_title(device, full_width?: true),
         {:ok, old_raw} <- Interface.raw_disc_title(device),
         {:ok, old_raw_full_width} <- Interface.raw_disc_title(device, full_width?: true),
         :ok <-
           maybe_rename_full_width(
             device,
             new_full_width,
             old_full_width,
             old_raw,
             old_raw_full_width
           ) do
      if new_name == old_name do
        :ok
      else
        Interface.set_disc_title(device, with_groups(new_name, old_raw, "0;", "//"))
      end
    end
  end

  defp maybe_rename_full_width(_device, nil, _old, _old_raw, _old_raw_full_width), do: :ok

  defp maybe_rename_full_width(device, new_full_width, old_full_width, old_raw, old_raw_fw) do
    if new_full_width == old_full_width do
      :ok
    else
      # The reference inspects the half-width raw title for full-width
      # group markers; kept for behavior parity.
      title =
        if String.contains?(old_raw, "／／") do
          replace_title_keeping_groups(old_raw_fw, new_full_width, old_raw, "０；", "／／")
        else
          new_full_width
        end

      Interface.set_disc_title(device, title, full_width?: true)
    end
  end

  defp with_groups(new_name, old_raw, marker, delimiter) do
    if String.contains?(old_raw, delimiter) do
      replace_title_keeping_groups(old_raw, new_name, old_raw, marker, delimiter)
    else
      new_name
    end
  end

  defp replace_title_keeping_groups(raw, new_name, marker_source, marker, delimiter) do
    replacement = if new_name == "", do: "", else: marker <> new_name <> delimiter

    if String.starts_with?(marker_source, marker) do
      String.replace(
        raw,
        ~r/^#{Regex.escape(marker)}.*?#{Regex.escape(delimiter)}/u,
        replacement
      )
    else
      marker <> new_name <> delimiter <> raw
    end
  end

  ## Transfers

  @doc """
  Upload a track from the disc (MZ-RH1 only), returning the disc format
  and the audio prefixed with a playable header: AEA for SP, WAV with
  the ATRAC3 format tag for LP2/LP4.

  Options are passed to `Netmd.Interface.save_track_to_binary/3`.
  """
  @spec upload(Device.t(), non_neg_integer(), keyword()) ::
          {:ok, %{format: byte(), data: binary()}} | error()
  def upload(device, track, opts \\ []) do
    with {:ok, %{format: format, data: data}} <-
           Interface.save_track_to_binary(device, track, opts),
         {:ok, header} <- upload_header(device, track, format, data) do
      {:ok, %{format: format, data: header <> data}}
    end
  end

  # SP stereo (6) and SP mono (4) get AEA headers, LP2 (2) and LP4 (0)
  # get WAV headers.
  defp upload_header(device, track, format, data) when format in [4, 6] do
    with {:ok, title} <- Interface.track_title(device, track) do
      channels = if format == 6, do: 2, else: 1
      {:ok, Audio.aea_header(title, channels, div(byte_size(data), 212))}
    end
  end

  defp upload_header(_device, _track, format, data) when format in [0, 2] do
    {:ok, Audio.wav_header(format, byte_size(data))}
  end

  @doc """
  Get the device ready for downloads: wait until it is idle, clear any
  stale secure session and take control.
  """
  @spec prepare_download(Device.t(), keyword()) :: :ok | error()
  def prepare_download(device, opts \\ []) do
    with :ok <- await_ready(device, Keyword.get(opts, :attempts, 250)) do
      # Clear any stale session; failures mean there was none.
      _ = Interface.session_key_forget(device)
      _ = Interface.leave_secure_session(device)

      with :ok <- Interface.acquire(device) do
        # Rejected on Sharp devices; ignored like the reference.
        _ = Interface.disable_new_track_protection(device, 1)
        :ok
      end
    end
  end

  defp await_ready(_device, 0), do: {:error, :not_ready}

  defp await_ready(device, attempts) do
    with {:ok, %{state: state}} <- device_status(device) do
      if state in [:ready, :disc_blank] do
        :ok
      else
        Process.sleep(200)
        await_ready(device, attempts - 1)
      end
    end
  end

  @doc """
  Download a track to the disc: prepare, run a secure session, transfer,
  and release the device.

  Options: `:progress`, `:settle_ms` (see `Netmd.Interface.send_track/8`),
  `:disc_format` (see `Netmd.Session.download_track/3`) and `:attempts`
  (see `prepare_download/2`).
  """
  @spec download(Device.t(), Track.t(), keyword()) ::
          {:ok, %{track: non_neg_integer(), uuid: binary(), ccid: binary()}} | error()
  def download(device, %Track{} = track, opts \\ []) do
    with :ok <- prepare_download(device, Keyword.take(opts, [:attempts])),
         {:ok, session} <- Session.start(device),
         {:ok, result} <-
           Session.download_track(
             session,
             track,
             Keyword.take(opts, [:progress, :settle_ms, :disc_format])
           ),
         :ok <- Session.close(session),
         :ok <- Interface.release(device) do
      {:ok, result}
    end
  end
end
