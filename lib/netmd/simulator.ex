defmodule Netmd.Simulator do
  @moduledoc """
  A virtual NetMD device that runs the whole library in-process.

  This is a `Netmd.Transport` backed by a `GenServer` that decodes the
  NetMD control and bulk protocol and keeps disc state, so you can drive
  the real library against a simulated recorder without any USB, VM or
  root access:

      {:ok, device} = Netmd.open(transport: Netmd.Simulator)
      {:ok, disc} = Netmd.list_content(device)
      :ok = Netmd.play(device)

  Pass `disc: %Netmd.Simulator.Disc{...}` to `open/1` to start from a
  custom disc; the default is a small demo disc. State survives across
  calls and mutates in response to edits and downloads, so a listing after
  a rename or download reflects the change.

  It implements the command subset the library actually uses: disc and
  track listing, status and playback, editing, the secure download
  session, and enough of factory mode to authenticate. Unknown commands
  answer `not implemented`, which surfaces as a clear error.
  """

  @behaviour Netmd.Transport

  use GenServer

  alias Netmd.Crypto
  alias Netmd.EKB
  alias Netmd.Query
  alias Netmd.Simulator.Disc
  alias Netmd.SJIS

  # AV/C response status bytes (first byte of every reply).
  @accepted 0x09
  @rejected 0x0A
  @not_implemented 0x08

  # Operating-status numbers the library maps to named states.
  @operating_status %{
    ready: 50_687,
    playing: 50_037,
    paused: 50_045,
    fast_forward: 49_983,
    rewind: 49_999
  }

  defmodule Disc do
    @moduledoc "The virtual disc a `Netmd.Simulator` presents."

    defstruct present: true,
              writable: true,
              write_protected: false,
              raw_title: "Demo Disc",
              raw_full_title: "",
              tracks: [],
              used: {0, 5, 0, 0},
              total: {1, 20, 0, 0},
              left: {1, 15, 0, 0}

    @typedoc "A track on the virtual disc."
    @type track :: %{
            title: String.t(),
            full_title: String.t(),
            codec: byte(),
            channel: byte(),
            protected: byte(),
            length: {byte(), byte(), byte(), byte()}
          }

    @type t :: %__MODULE__{}

    @doc "A small demo disc with two tracks."
    @spec demo() :: t()
    def demo() do
      %__MODULE__{
        raw_title: "Demo Disc",
        tracks: [
          track("Opening", 0x90, 0x00, {0, 3, 20, 0}),
          track("Second Song", 0x92, 0x00, {0, 4, 12, 0})
        ]
      }
    end

    @doc "Build a track map."
    @spec track(String.t(), byte(), byte(), {byte(), byte(), byte(), byte()}) :: track()
    def track(title, codec, channel, length) do
      %{
        title: title,
        full_title: "",
        codec: codec,
        channel: channel,
        protected: 0x00,
        length: length
      }
    end
  end

  ## Brain

  @doc """
  Start the device brain as a standalone process.

  The same process serves both this module's `Netmd.Transport` callbacks
  and `Netmd.Simulator.Gadget`. Options: `:disc`, `:vendor_id`,
  `:product_id`, `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    config = %{
      disc: Keyword.get(opts, :disc, Disc.demo()),
      vendor_id: Keyword.get(opts, :vendor_id, 0x054C),
      product_id: Keyword.get(opts, :product_id, 0x00C8)
    }

    GenServer.start_link(__MODULE__, config, Keyword.take(opts, [:name]))
  end

  ## Transport behaviour

  @impl Netmd.Transport
  def open(opts) do
    with {:ok, pid} <- start_link(opts) do
      {:ok, pid,
       %{
         vendor_id: Keyword.get(opts, :vendor_id, 0x054C),
         product_id: Keyword.get(opts, :product_id, 0x00C8)
       }}
    end
  end

  @impl Netmd.Transport
  def close(pid), do: GenServer.stop(pid)

  @impl Netmd.Transport
  def control_in(pid, request, _value, _index, length),
    do: GenServer.call(pid, {:control_in, request, length})

  @impl Netmd.Transport
  def control_out(pid, request, _value, _index, data),
    do: GenServer.call(pid, {:control_out, request, data})

  @impl Netmd.Transport
  def bulk_in(pid, length, _timeout), do: GenServer.call(pid, {:bulk_in, length})

  @impl Netmd.Transport
  def bulk_out(pid, data, _timeout), do: GenServer.call(pid, {:bulk_out, data})

  ## Server

  @impl GenServer
  def init(config) do
    {:ok,
     %{
       disc: config.disc,
       vendor_id: config.vendor_id,
       product_id: config.product_id,
       state: :ready,
       track: 0,
       reply: <<>>,
       bulk_out: <<>>,
       bulk_out_expected: 0,
       bulk_in: <<>>,
       session_key: nil,
       host_nonce: nil,
       pending_track: nil
     }}
  end

  @impl GenServer
  def handle_call({:control_in, 0x01, _len}, _from, state) do
    # Reply-length poll: the length lives in byte 2 of a 4-byte response.
    {:reply, {:ok, <<0, 0, byte_size(state.reply), 0>>}, state}
  end

  def handle_call({:control_in, request, len}, _from, state) when request in [0x81, 0xFF] do
    # Read the queued reply (and clear it), truncated to the requested length.
    reply = binary_part(state.reply, 0, min(len, byte_size(state.reply)))
    {:reply, {:ok, reply}, %{state | reply: <<>>}}
  end

  def handle_call({:control_out, request, <<_status, query::binary>>}, _from, state)
      when request in [0x80, 0xFF] do
    {reply, state} = dispatch(query, state)
    {:reply, :ok, %{state | reply: reply}}
  end

  def handle_call({:control_out, _request, <<>>}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:bulk_in, length}, _from, state) do
    data = binary_part(state.bulk_in, 0, min(length, byte_size(state.bulk_in)))
    rest = binary_part(state.bulk_in, byte_size(data), byte_size(state.bulk_in) - byte_size(data))
    {:reply, {:ok, data}, %{state | bulk_in: rest}}
  end

  def handle_call({:bulk_out, data}, _from, state) do
    {:reply, :ok, accept_bulk(state, data)}
  end

  ## Command dispatch
  #
  # Each clause matches a command the library sends and returns
  # `{reply_with_status_byte, new_state}`. The reply's first byte is the
  # AV/C status; the rest mirrors the format the library scans.

  # Descriptor open/close: acknowledged and ignored by the library.
  defp dispatch(<<0x18, 0x08, _rest::binary>> = query, state), do: {accept(query), state}

  # Exclusive control acquire / release: echoed back verbatim.
  defp dispatch(<<0xFF, 0x01, _::binary>> = query, state), do: {accept(query), state}

  # Status block.
  defp dispatch(<<0x18, 0x09, 0x80, 0x01, 0x02, 0x30, _::binary>>, state) do
    presence = if state.disc.present, do: 0x40, else: 0x80
    block = <<0, 0, 0, 0, presence, 0, 0, 0>>
    {accept(Query.format("1809 8001 0230 8800 0030 8804 00 1000 00090000 %x", [block])), state}
  end

  # Playback status (also serves full operating status): bytes 4-5 carry
  # the operating-status number.
  defp dispatch(<<0x18, 0x09, 0x80, 0x01, 0x03, 0x30, p1::16, _::binary>>, state)
       when p1 in [0x8801, 0x8802] do
    number = Map.fetch!(@operating_status, state.state)
    block = <<0, 0, 0, 0, div(number, 256), rem(number, 256)>>

    payload =
      <<0x18, 0x09, 0x80, 0x01, 0x03, 0x30, p1::16, 0x00, 0x30, 0x88, 0x05, 0x00, 0x30, 0x88,
        0x06, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
        length_prefixed(block) <> <<0x00>>

    {accept(payload), state}
  end

  # Playback position.
  defp dispatch(<<0x18, 0x09, 0x80, 0x01, 0x04, 0x30, _::binary>>, state) do
    {h, m, s, f} = current_position(state)

    # seven skipped words the library ignores
    # %? then %?00 then 00%?0000 (7 bytes of filler)
    payload =
      <<0x18, 0x09, 0x80, 0x01, 0x04, 0x30>> <>
        <<0x88, 0x02, 0x00, 0x30, 0x88, 0x05, 0x00, 0x30, 0x00, 0x03, 0x00, 0x30, 0x00, 0x02>> <>
        <<0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>> <>
        <<0x00, 0x0B, 0x00, 0x02, 0x00, 0x07, 0x00>> <>
        <<state.track::16>> <> bcd(h) <> bcd(m) <> bcd(s) <> bcd(f)

    {accept(payload), state}
  end

  # Disc flags: bit 4 writable, bit 6 write-protected.
  defp dispatch(<<0x18, 0x06, 0x01, 0x10, 0x10, 0x00, _::binary>>, state) do
    flags =
      if(state.disc.writable, do: 0x10, else: 0x00) +
        if state.disc.write_protected, do: 0x40, else: 0x00

    {accept(Query.format("1806 01101000 1000 0001000b %b", [flags])), state}
  end

  # Track count.
  defp dispatch(<<0x18, 0x06, 0x02, 0x10, 0x10, 0x01, 0x30, 0x00, 0x10, 0x00, _::binary>>, state) do
    count = length(state.disc.tracks)

    {accept(Query.format("1806 02101001 3000 1000 1000 00000000 0006 0010000200 %b", [count])),
     state}
  end

  # Disc capacity (three durations: used, total, left).
  defp dispatch(<<0x18, 0x06, 0x02, 0x10, 0x10, 0x00, 0x30, 0x80, _::binary>>, state) do
    {accept(capacity_reply(state.disc)), state}
  end

  # Disc title read (whole title in one chunk).
  defp dispatch(<<0x18, 0x06, 0x02, 0x20, 0x18, 0x01, 0x00, wchar, _::binary>>, state) do
    title = if wchar == 1, do: state.disc.raw_full_title, else: state.disc.raw_title
    {accept(disc_title_reply(wchar, SJIS.encode(title))), state}
  end

  # Track title read.
  defp dispatch(<<0x18, 0x06, 0x02, 0x20, 0x18, wchar, track::16, _::binary>>, state)
       when wchar in [0x02, 0x03] do
    case Enum.at(state.disc.tracks, track) do
      nil ->
        {reject(), state}

      %{} = t ->
        title = if wchar == 0x03, do: t.full_title, else: t.title
        {accept(track_title_reply(wchar, SJIS.encode(title))), state}
    end
  end

  # Track info: length or encoding, by the sub-parameters.
  defp dispatch(
         <<0x18, 0x06, 0x02, 0x20, 0x10, 0x01, track::16, p1::16, p2::16, _::binary>>,
         state
       ) do
    case Enum.at(state.disc.tracks, track) do
      nil -> {reject(), state}
      t -> {accept(track_info_reply(track, p1, p2, t)), state}
    end
  end

  # Track flags.
  defp dispatch(<<0x18, 0x06, 0x01, 0x20, 0x10, 0x01, track::16, _::binary>>, state) do
    case Enum.at(state.disc.tracks, track) do
      nil ->
        {reject(), state}

      t ->
        {accept(Query.format("1806 01201001 %w 10 00 00010008 %b", [track, t.protected])), state}
    end
  end

  # Set disc title.
  defp dispatch(<<0x18, 0x07, 0x02, 0x20, 0x18, 0x01, 0x00, wchar, _::binary>> = query, state) do
    {:ok, [_wchar, _new_len, _old_len, title]} =
      Query.scan(query, "1807 02201801 00%b 3000 0a00 5000 %w 0000 %w %*")

    decoded = SJIS.decode(title)

    disc =
      if wchar == 1,
        do: %{state.disc | raw_full_title: decoded},
        else: %{state.disc | raw_title: decoded}

    {accept(Query.format("1807 02201801 00%b 3000 0a00 5000 0000 0000 0000", [wchar])),
     %{state | disc: disc}}
  end

  # Set track title.
  defp dispatch(<<0x18, 0x07, 0x02, 0x20, 0x18, wchar, track::16, _::binary>> = query, state)
       when wchar in [0x02, 0x03] do
    {:ok, [_wchar, _track, _new_len, _old_len, title]} =
      Query.scan(query, "1807 022018%b %w 3000 0a00 5000 %w 0000 %w %*")

    decoded = SJIS.decode(title)
    disc = update_track(state.disc, track, wchar, decoded)

    {accept(Query.format("1807 022018%b %w 3000 0a00 5000 0000 0000 0000", [wchar, track])),
     %{state | disc: disc}}
  end

  # Playback actions.
  defp dispatch(<<0x18, 0xC3, 0xFF, action, _::binary>>, state) do
    new_state =
      case action do
        0x75 -> :playing
        0x7D -> :paused
        0x39 -> :fast_forward
        0x49 -> :rewind
        _ -> state.state
      end

    {accept(Query.format("18c3 00 %b 000000", [action])), %{state | state: new_state}}
  end

  defp dispatch(<<0x18, 0xC5, _::binary>>, state) do
    {accept(Query.format("18c5 00 00000000")), %{state | state: :ready}}
  end

  # Eject.
  defp dispatch(<<0x18, 0xC1, _::binary>>, state) do
    {accept(Query.format("18c1 00 6000")), %{state | disc: %{state.disc | present: false}}}
  end

  # Seek to a track.
  defp dispatch(<<0x18, 0x50, 0xFF, 0x01, _::binary>> = query, state) do
    {:ok, [track]} = Query.scan(query, "1850 ff010000 0000 %w")
    track = min(track, max(length(state.disc.tracks) - 1, 0))
    {accept(Query.format("1850 00010000 0000 %w", [track])), %{state | track: track}}
  end

  # Track change (next / previous / restart).
  defp dispatch(<<0x18, 0x50, 0xFF, 0x10, _::binary>>, state) do
    {accept(Query.format("1850 0010 00000000 0000")), state}
  end

  # Erase whole disc.
  defp dispatch(<<0x18, 0x40, 0xFF, 0x00, 0x00>>, state) do
    {accept(Query.format("1840 00 0000")), %{state | disc: %{state.disc | tracks: []}}}
  end

  # Erase a track.
  defp dispatch(<<0x18, 0x40, 0xFF, 0x01, 0x00, 0x20, 0x10, 0x01, track::16>>, state) do
    tracks = List.delete_at(state.disc.tracks, track)

    {accept(Query.format("1840 0001 00 201001 %w", [track])),
     %{state | disc: %{state.disc | tracks: tracks}}}
  end

  # Move a track.
  defp dispatch(<<0x18, 0x43, 0xFF, _::binary>> = query, state) do
    {:ok, [source, dest]} = Query.scan(query, "1843 ff00 00 201001 %w 201001 %w")
    tracks = move(state.disc.tracks, source, dest)

    {accept(Query.format("1843 0000 00 201001 %w 201001 %w", [source, dest])),
     %{state | disc: %{state.disc | tracks: tracks}}}
  end

  # Secure session and factory commands share the 1800 080046 envelope.
  defp dispatch(<<0x18, 0x00, 0x08, 0x00, 0x46, _::binary>> = query, state),
    do: dispatch_secure(query, state)

  # Factory authentication and device info.
  defp dispatch(<<0x18, 0x01, 0xFF, _::binary>> = query, state), do: {accept(query), state}
  defp dispatch(<<0x18, 0x02, 0xFF, _::binary>> = query, state), do: {accept(query), state}

  defp dispatch(<<0x18, 0x12, 0xFF>>, state) do
    # A plausible Type-S device code.
    {accept(Query.format("1812 00 %b %b %b %B", [0x21, 0x00, 0x00, 21])), state}
  end

  defp dispatch(<<0x18, 0x13, 0xFF>>, state) do
    {accept(Query.format("1813 00 00 %B", [21])), state}
  end

  defp dispatch(_query, state), do: {<<@not_implemented>>, state}

  ## Secure session

  defp dispatch_secure(
         <<_::binary-size(5), 0xF0, 0x03, 0x01, 0x03, sub, _::binary>> = query,
         state
       ) do
    secure(sub, query, state)
  end

  defp dispatch_secure(<<_::binary-size(5), 0xF0, 0x03, 0x01, 0x04, 0x82, _::binary>>, state) do
    {accept(Query.format("1800 080046 f0030104 82 00")), state}
  end

  defp dispatch_secure(_query, state), do: {<<@not_implemented>>, state}

  # enter secure session
  defp secure(0x80, _query, state),
    do: {accept(Query.format("1800 080046 f0030103 80 00")), state}

  # leave secure session
  defp secure(0x81, _query, state),
    do: {accept(Query.format("1800 080046 f0030103 81 00")), state}

  # session key forget
  defp secure(0x21, _query, state),
    do: {accept(Query.format("1800 080046 f0030103 21 00 000000")), %{state | session_key: nil}}

  # terminate
  defp secure(0x2A, _query, state),
    do: {accept(Query.format("1800 080046 f0030103 2a 00")), state}

  # disable new track protection
  defp secure(0x2B, query, state) do
    {:ok, [_value]} = Query.scan(query, "1800 080046 f0030103 2b ff %w")
    {accept(Query.format("1800 080046 f0030103 2b 00 0000")), state}
  end

  # leaf id
  defp secure(0x11, _query, state) do
    {accept(Query.format("1800 080046 f0030103 11 00 %*", [<<0::size(64)>>])), state}
  end

  # send key data
  defp secure(0x12, _query, state) do
    {accept(Query.format("1800 080046 f0030103 12 01 0000 00000000")), state}
  end

  # session key exchange: derive the same session key the host will.
  defp secure(0x20, query, state) do
    {:ok, [host_nonce]} = Query.scan(query, "1800 080046 f0030103 20 ff 000000 %*")
    device_nonce = <<0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7>>
    session_key = Crypto.retailmac(EKB.open_source().root_key, host_nonce <> device_nonce)

    {accept(Query.format("1800 080046 f0030103 20 00 000000 %*", [device_nonce])),
     %{state | session_key: session_key, host_nonce: host_nonce}}
  end

  # setup download
  defp secure(0x22, _query, state) do
    {accept(Query.format("1800 080046 f0030103 22 00 0000")), state}
  end

  # send track: announce; the real payload arrives over bulk.
  defp secure(0x28, query, state) do
    {:ok, [wireformat, _discformat, _frames, total_bytes]} =
      Query.scan(query, "1800 080046 f0030103 28 ff 000100 1001 ffff 00 %b %b %d %d")

    interim = accept(Query.format("1800 080046 f0030103 28 00 000100 1001 0000 00 %*", [<<>>]))

    {interim,
     %{
       state
       | bulk_out: <<>>,
         bulk_out_expected: total_bytes,
         pending_track: Disc.track("", wireformat_to_codec(wireformat), 0x00, {0, 0, 1, 0})
     }}
  end

  # commit track
  defp secure(0x48, query, state) do
    {:ok, [track, _auth]} = Query.scan(query, "1800 080046 f0030103 48 ff 00 1001 %w %*")
    {accept(Query.format("1800 080046 f0030103 48 00 00 1001 %w", [track])), state}
  end

  # track UUID
  defp secure(0x23, query, state) do
    {:ok, [track]} = Query.scan(query, "1800 080046 f0030103 23 ff 1001 %w")
    {accept(Query.format("1800 080046 f0030103 23 00 1001 %w %*", [track, <<0::64>>])), state}
  end

  defp secure(_sub, _query, state), do: {<<@not_implemented>>, state}

  ## Bulk (track download payload)

  defp accept_bulk(%{bulk_out_expected: 0} = state, _data), do: state

  defp accept_bulk(state, data) do
    received = state.bulk_out <> data

    if byte_size(received) >= state.bulk_out_expected do
      finish_download(%{state | bulk_out: received})
    else
      %{state | bulk_out: received}
    end
  end

  defp finish_download(state) do
    track = state.pending_track
    new_index = length(state.disc.tracks)
    disc = %{state.disc | tracks: state.disc.tracks ++ [track]}

    # The library decrypts this with the session key to read the UUID/CCID.
    confirmation =
      Crypto.des_cbc_encrypt(
        state.session_key,
        <<0::64>>,
        "SIMUUID0" <> <<0, 0, 0, 0>> <> "SIMCONTENTID12345678"
      )

    reply =
      Query.format(
        "1800 080046 f0030103 28 00 000100 1001 %w 00 0000 00000000 00000000 %*",
        [new_index, confirmation]
      )

    %{
      state
      | disc: disc,
        reply: accept(reply),
        bulk_out: <<>>,
        bulk_out_expected: 0,
        pending_track: nil
    }
  end

  ## Reply builders

  defp accept(payload), do: <<@accepted>> <> payload
  defp reject(), do: <<@rejected>>

  defp length_prefixed(data), do: <<byte_size(data)::16>> <> data

  defp bcd(value), do: Query.int_to_bcd(value, 1)

  defp disc_title_reply(wchar, title) do
    total = byte_size(title)

    Query.format("1806 02201801 00%b 3000 0a00 1000 %w 0000 %w 000a %w %*", [
      wchar,
      total + 6,
      0,
      total,
      title
    ])
  end

  defp track_title_reply(wchar, title) do
    Query.format("1806 022018%b 0000 3000 0a00 1000 00000000 0000000a %x", [wchar, title])
  end

  defp track_info_reply(track, 0x3000, 0x0100, t) do
    {h, m, s, f} = t.length
    blob = <<0x00, 0x01, 0x00, 0x06, 0x00, 0x00>> <> bcd(h) <> bcd(m) <> bcd(s) <> bcd(f)
    track_info_wrap(track, 0x3000, 0x0100, blob)
  end

  defp track_info_reply(track, 0x3080, 0x0700, t) do
    blob = <<0x80, 0x07, 0x00, 0x04, 0x01, 0x10, t.codec, t.channel>>
    track_info_wrap(track, 0x3080, 0x0700, blob)
  end

  defp track_info_wrap(track, p1, p2, blob) do
    Query.format("1806 02201001 %w %w %w 1000 00000000 %x", [track, p1, p2, blob])
  end

  defp capacity_reply(disc) do
    {uh, um, us, uf} = disc.used
    {th, tm, ts, tf} = disc.total
    {lh, lm, ls, lf} = disc.left

    Query.format(
      "1806 02101000 3080 0300 1000 001d0000 001b 8003 0017 8000 " <>
        "0005 %W %B %B %B 0005 %W %B %B %B 0005 %W %B %B %B",
      [uh, um, us, uf, th, tm, ts, tf, lh, lm, ls, lf]
    )
  end

  ## State helpers

  defp current_position(state) do
    case Enum.at(state.disc.tracks, state.track) do
      %{length: length} -> length
      _ -> {0, 0, 0, 0}
    end
  end

  defp update_track(disc, track, wchar, title) do
    tracks =
      List.update_at(disc.tracks, track, fn t ->
        if wchar == 0x03, do: %{t | full_title: title}, else: %{t | title: title}
      end)

    %{disc | tracks: tracks}
  end

  defp move(tracks, source, dest) do
    {track, rest} = List.pop_at(tracks, source)
    List.insert_at(rest, dest, track)
  end

  defp wireformat_to_codec(0x00), do: 0x90
  defp wireformat_to_codec(0x90), do: 0x92
  defp wireformat_to_codec(0x94), do: 0x92
  defp wireformat_to_codec(0xA8), do: 0x93
  defp wireformat_to_codec(_), do: 0x90
end
