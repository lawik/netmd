defmodule Netmd.Session do
  @moduledoc """
  The secure session needed to download tracks, ported from netmd-js's
  MDSession.

  Negotiates a session key by sending an enabling key block and
  exchanging nonces, then encrypts and streams track data.

      {:ok, session} = Netmd.Session.start(device)
      {:ok, %{track: n}} = Netmd.Session.download_track(session, track)
      :ok = Netmd.Session.close(session)
  """

  alias Netmd.Crypto
  alias Netmd.Device
  alias Netmd.EKB
  alias Netmd.Interface
  alias Netmd.Track

  @enforce_keys [:device, :key]
  defstruct [:device, :key]

  @typedoc "An established secure session."
  @type t :: %__MODULE__{device: Device.t(), key: <<_::64>>}

  @doc """
  Enter the secure session and negotiate a session key.

  Accepts `host_nonce: <<_::64>>` for a deterministic exchange (tests);
  the default is random.
  """
  @spec start(Device.t(), keyword()) :: {:ok, t()} | Interface.error()
  def start(device, opts \\ []) do
    host_nonce = Keyword.get_lazy(opts, :host_nonce, fn -> :crypto.strong_rand_bytes(8) end)

    with :ok <- Interface.enter_secure_session(device),
         {:ok, leaf_id} <- Interface.leaf_id(device),
         ekb = EKB.for_device(leaf_id, device.vendor_id, device.product_id),
         :ok <- Interface.send_key_data(device, ekb),
         {:ok, device_nonce} <- Interface.session_key_exchange(device, host_nonce) do
      key = Crypto.retailmac(ekb.root_key, host_nonce <> device_nonce)
      {:ok, %__MODULE__{device: device, key: key}}
    end
  end

  @doc """
  Download a track: set up the transfer, stream the encrypted packets,
  title the new track and commit it.

  Options:

    * `:disc_format` - override the disc format byte derived from the
      track's wire format
    * `:progress` and `:settle_ms` - see `Netmd.Interface.send_track/8`
  """
  @spec download_track(t(), Track.t(), keyword()) ::
          {:ok, %{track: non_neg_integer(), uuid: binary(), ccid: binary()}}
          | Interface.error()
  def download_track(%__MODULE__{device: device, key: key}, %Track{} = track, opts \\ []) do
    disc_format = Keyword.get(opts, :disc_format, Track.disc_format(track))

    with :ok <- Interface.setup_download(device, Track.content_id(), Track.kek(), key),
         {:ok, result} <-
           Interface.send_track(
             device,
             Track.wireformat(track),
             disc_format,
             Track.frame_count(track),
             Track.total_size(track),
             Track.packets(track),
             key,
             Keyword.take(opts, [:progress, :settle_ms])
           ),
         :ok <- Interface.set_track_title(device, result.track, track.title),
         :ok <- maybe_set_full_width_title(device, result.track, track.full_width_title),
         :ok <- Interface.commit_track(device, result.track, key) do
      {:ok, result}
    end
  end

  @doc """
  Forget the session key (errors ignored) and leave the secure session.
  """
  @spec close(t()) :: :ok | Interface.error()
  def close(%__MODULE__{device: device}) do
    _ = Interface.session_key_forget(device)
    Interface.leave_secure_session(device)
  end

  defp maybe_set_full_width_title(_device, _track, nil), do: :ok

  defp maybe_set_full_width_title(device, track, title),
    do: Interface.set_track_title(device, track, title, full_width?: true)
end
