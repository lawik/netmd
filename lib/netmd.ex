defmodule Netmd do
  @moduledoc """
  Drive MiniDisc recorders over NetMD USB.

  A port of the NetMD protocol as implemented by netmd-js and libnetmd
  (linux-minidisc), on top of `CircuitsUsb`.

      {:ok, device} = Netmd.open()
      {:ok, disc} = Netmd.list_content(device)
      :ok = Netmd.play(device)

      track = %Netmd.Track{title: "New Song", format: :lp2, data: atrac3_data}
      {:ok, %{track: n}} = Netmd.download(device, track)

  This module is a convenience facade; the layers underneath are usable
  on their own:

    * `Netmd.Commands` - disc listing, renaming, transfers
    * `Netmd.Interface` - the full NetMD command set
    * `Netmd.Session` / `Netmd.Track` - secure download sessions
    * `Netmd.Device` - the raw USB exchange protocol
    * `Netmd.Query` - the query format/scan DSL
  """

  alias Netmd.Commands
  alias Netmd.Device
  alias Netmd.Interface

  @doc "Open the first NetMD device found. See `Netmd.Device.open/1`."
  @spec open(keyword()) :: {:ok, Device.t()} | {:error, term()}
  defdelegate open(opts \\ []), to: Device

  @doc "Close the device."
  @spec close(Device.t()) :: :ok
  defdelegate close(device), to: Device

  @doc "Device state (disc presence, playback state, position)."
  @spec device_status(Device.t()) :: {:ok, map()} | {:error, term()}
  defdelegate device_status(device), to: Commands

  @doc "Full disc listing. See `Netmd.Commands.list_content/1`."
  @spec list_content(Device.t()) :: {:ok, Netmd.Disc.t()} | {:error, term()}
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

  @doc "Skip to the next track."
  @spec next_track(Device.t()) :: :ok | {:error, term()}
  defdelegate next_track(device), to: Interface

  @doc "Skip to the previous track."
  @spec previous_track(Device.t()) :: :ok | {:error, term()}
  defdelegate previous_track(device), to: Interface

  @doc "Seek to a track (zero-based)."
  @spec goto_track(Device.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate goto_track(device, track), to: Interface

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

  @doc "Rename the disc, preserving groups. See `Netmd.Commands.rename_disc/3`."
  @spec rename_disc(Device.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate rename_disc(device, name, opts \\ []), to: Commands

  @doc "Rename a track (zero-based)."
  @spec rename_track(Device.t(), non_neg_integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate rename_track(device, track, title, opts \\ []),
    to: Interface,
    as: :set_track_title

  @doc "Download a track to the disc. See `Netmd.Commands.download/3`."
  @spec download(Device.t(), Netmd.Track.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate download(device, track, opts \\ []), to: Commands

  @doc "Upload a track from the disc (MZ-RH1 only). See `Netmd.Commands.upload/3`."
  @spec upload(Device.t(), non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate upload(device, track, opts \\ []), to: Commands

  @doc """
  Enter factory mode for direct memory access and patching. Dangerous;
  see `Netmd.Factory`.
  """
  @spec factory(Device.t()) :: {:ok, Netmd.Factory.t()} | {:error, term()}
  defdelegate factory(device), to: Netmd.Factory, as: :open
end
