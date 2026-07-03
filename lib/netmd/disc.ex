defmodule Netmd.Disc do
  @moduledoc """
  Disc contents as returned by `Netmd.Commands.list_content/1`.
  """

  defstruct title: "",
            full_width_title: "",
            writable: false,
            write_protected: false,
            used: 0,
            left: 0,
            total: 0,
            track_count: 0,
            groups: []

  @typedoc "A disc: durations are in frames (512 frames per second)."
  @type t :: %__MODULE__{
          title: String.t(),
          full_width_title: String.t(),
          writable: boolean(),
          write_protected: boolean(),
          used: non_neg_integer(),
          left: non_neg_integer(),
          total: non_neg_integer(),
          track_count: non_neg_integer(),
          groups: [Netmd.Disc.Group.t()]
        }

  defmodule Group do
    @moduledoc """
    A track group; `title: nil` marks the ungrouped tracks entry.
    """

    defstruct [:index, :title, :full_width_title, tracks: []]

    @typedoc "A group of tracks."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            title: String.t() | nil,
            full_width_title: String.t() | nil,
            tracks: [Netmd.Disc.Track.t()]
          }
  end

  defmodule Track do
    @moduledoc """
    A track listing entry. Duration is in frames.
    """

    defstruct [:index, :title, :full_width_title, :duration, :channel, :encoding, :protection]

    @typedoc "A track on the disc."
    @type t :: %__MODULE__{
            index: non_neg_integer(),
            title: String.t() | nil,
            full_width_title: String.t() | nil,
            duration: non_neg_integer(),
            channel: :stereo | :mono | byte(),
            encoding: :sp | :lp2 | :lp4 | byte(),
            protection: :protected | :unprotected | byte()
          }
  end

  @doc "All tracks across all groups."
  @spec tracks(t()) :: [Netmd.Disc.Track.t()]
  def tracks(%__MODULE__{groups: groups}), do: Enum.flat_map(groups, & &1.tracks)

  @doc "Total number of tracks in the listing."
  @spec count_tracks(t()) :: non_neg_integer()
  def count_tracks(%__MODULE__{} = disc), do: length(tracks(disc))
end
