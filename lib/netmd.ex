defmodule NetMD do
  @moduledoc """
  Drive MiniDisc recorders over NetMD USB.

  A port of the NetMD protocol as implemented by netmd-js and libnetmd
  (linux-minidisc), on top of `BodgeUSB`.

      {:ok, device} = NetMD.open()
      {:ok, disc} = NetMD.list_content(device)
      :ok = NetMD.play(device)

      track = %NetMD.Track{title: "New Song", format: :lp2, data: atrac3_data}
      {:ok, %{track: n}} = NetMD.download(device, track)

  This module is a convenience facade; the layers underneath are usable
  on their own:

    * `NetMD.Commands` - disc listing, renaming, transfers
    * `NetMD.Interface` - the full NetMD command set
    * `NetMD.Session` / `NetMD.Track` - secure download sessions
    * `NetMD.Device` - the raw USB exchange protocol
    * `NetMD.Query` - the query format/scan DSL
  """

  alias NetMD.Commands
  alias NetMD.Device
  alias NetMD.Interface

  @doc "List all connected NetMD devices. See `NetMD.Device.list/1`."
  @spec list_devices(keyword()) :: [Device.listing()]
  defdelegate list_devices(opts \\ []), to: Device, as: :list

  @doc "Open the first NetMD device found. See `NetMD.Device.open/1`."
  @spec open(keyword()) :: {:ok, Device.t()} | {:error, term()}
  defdelegate open(opts \\ []), to: Device

  @doc "Close the device."
  @spec close(Device.t()) :: :ok
  defdelegate close(device), to: Device

  @doc """
  Subscribe to `{:netmd_status, status}` change events from the background
  poller. See `NetMD.Device.subscribe/2`.
  """
  @spec subscribe(Device.t(), pid()) :: :ok | {:error, :status_events_unavailable}
  defdelegate subscribe(device, pid \\ self()), to: Device

  @doc "Stop receiving status events. See `NetMD.Device.unsubscribe/2`."
  @spec unsubscribe(Device.t(), pid()) :: :ok | {:error, :status_events_unavailable}
  defdelegate unsubscribe(device, pid \\ self()), to: Device

  @doc "Device state (disc presence, playback state, position)."
  @spec device_status(Device.t()) :: {:ok, map()} | {:error, term()}
  defdelegate device_status(device), to: Commands

  @doc "Full disc listing. See `NetMD.Commands.list_content/1`."
  @spec list_content(Device.t()) :: {:ok, NetMD.Disc.t()} | {:error, term()}
  defdelegate list_content(device), to: Commands

  @doc "Start playback."
  @spec play(Device.t()) :: :ok | {:error, term()}
  defdelegate play(device), to: Interface

  @doc "Pause playback."
  @spec pause(Device.t()) :: :ok | {:error, term()}
  defdelegate pause(device), to: Interface

  @doc "Stop playback."
  @spec stop(Device.t()) :: :ok
  defdelegate stop(device), to: Interface

  @doc "Fast-forward."
  @spec fast_forward(Device.t()) :: :ok | {:error, term()}
  defdelegate fast_forward(device), to: Interface

  @doc "Rewind."
  @spec rewind(Device.t()) :: :ok | {:error, term()}
  defdelegate rewind(device), to: Interface

  @doc "Skip to the next track."
  @spec next_track(Device.t()) :: :ok | {:error, term()}
  defdelegate next_track(device), to: Interface

  @doc "Skip to the previous track."
  @spec previous_track(Device.t()) :: :ok | {:error, term()}
  defdelegate previous_track(device), to: Interface

  @doc "Restart the current track."
  @spec restart_track(Device.t()) :: :ok | {:error, term()}
  defdelegate restart_track(device), to: Interface

  @doc "Seek to a track (zero-based)."
  @spec goto_track(Device.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate goto_track(device, track), to: Interface

  @doc "Seek to a time within a track. See `NetMD.Interface.goto_time/3`."
  @spec goto_time(Device.t(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  defdelegate goto_time(device, track, opts \\ []), to: Interface

  @doc "Eject the disc."
  @spec eject_disc(Device.t()) :: :ok | {:error, term()}
  defdelegate eject_disc(device), to: Interface

  @doc "Erase the whole disc."
  @spec erase_disc(Device.t()) :: :ok | {:error, term()}
  defdelegate erase_disc(device), to: Interface

  @doc "Erase a track (zero-based)."
  @spec erase_track(Device.t(), non_neg_integer()) :: :ok | {:error, term()}
  defdelegate erase_track(device, track), to: Interface

  @doc "Move a track (both positions zero-based)."
  @spec move_track(Device.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defdelegate move_track(device, source, dest), to: Interface

  @doc "Rename the disc, preserving groups. See `NetMD.Commands.rename_disc/3`."
  @spec rename_disc(Device.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate rename_disc(device, name, opts \\ []), to: Commands

  @doc "Rename a track (zero-based)."
  @spec rename_track(Device.t(), non_neg_integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate rename_track(device, track, title, opts \\ []),
    to: Interface,
    as: :set_track_title

  @doc "Download a track to the disc. See `NetMD.Commands.download/3`."
  @spec download(Device.t(), NetMD.Track.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate download(device, track, opts \\ []), to: Commands

  @doc "Upload a track from the disc (MZ-RH1 only). See `NetMD.Commands.upload/3`."
  @spec upload(Device.t(), non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate upload(device, track, opts \\ []), to: Commands

  @doc """
  Enter factory mode for direct memory access and patching. Dangerous;
  see `NetMD.Factory`.
  """
  @spec factory(Device.t()) :: {:ok, NetMD.Factory.t()} | {:error, term()}
  defdelegate factory(device), to: NetMD.Factory, as: :open
end
