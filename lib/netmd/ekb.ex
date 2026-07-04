defmodule NetMD.EKB do
  @moduledoc """
  Enabling Key Blocks for the NetMD secure session, from netmd-js.

  The open-source EKB works with every stock device; decks with a
  corrupted (all `0xFF`) leaf ID get a purpose-built EKB by Sir68k.
  """

  @enforce_keys [:id, :root_key, :chain, :depth, :signature]
  defstruct [:id, :root_key, :chain, :depth, :signature]

  @typedoc "An enabling key block."
  @type t :: %__MODULE__{
          id: non_neg_integer(),
          root_key: <<_::128>>,
          chain: [<<_::128>>],
          depth: pos_integer(),
          signature: <<_::192>>
        }

  @doc """
  Pick the EKB for a device by its leaf ID and USB ids.
  """
  @spec for_device(binary(), 0..0xFFFF, 0..0xFFFF) :: t()
  def for_device(leaf_id, vendor_id, product_id) do
    if corrupted_deck?(leaf_id, vendor_id, product_id) do
      corrupted_deck()
    else
      open_source()
    end
  end

  @doc "The open-source EKB accepted by stock devices."
  @spec open_source() :: t()
  def open_source() do
    %__MODULE__{
      id: 0x26422642,
      root_key:
        <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x0F, 0xED, 0xCB, 0xA9, 0x87, 0x65,
          0x43, 0x21>>,
      chain: [
        <<0x25, 0x45, 0x06, 0x4D, 0xEA, 0xCA, 0x14, 0xF9, 0x96, 0xBD, 0xC8, 0xA4, 0x06, 0xC2,
          0x2B, 0x81>>,
        <<0xFB, 0x60, 0xBD, 0xDD, 0x0D, 0xBC, 0xAB, 0x84, 0x8A, 0x00, 0x5E, 0x03, 0x19, 0x4D,
          0x3E, 0xDA>>
      ],
      depth: 9,
      signature:
        <<0x8F, 0x2B, 0xC3, 0x52, 0xE8, 0x6C, 0x5E, 0xD3, 0x06, 0xDC, 0xAE, 0x18, 0xD2, 0xF3,
          0x8C, 0x7F, 0x89, 0xB5, 0xE1, 0x85, 0x55, 0xA1, 0x05, 0xEA>>
    }
  end

  @doc "EKB for Sony decks with a corrupted leaf ID, by Sir68k."
  @spec corrupted_deck() :: t()
  def corrupted_deck() do
    %__MODULE__{
      id: 0x13371337,
      # 'WMDPWMDPMiniDisc'
      root_key: "WMDPWMDPMiniDisc",
      chain: [
        <<0xB1, 0xD4, 0xAF, 0xFA, 0x80, 0xA0, 0xC9, 0x03, 0xC2, 0x58, 0x4B, 0x1B, 0x44, 0xAF,
          0xC4, 0xA6>>
      ],
      depth: 9,
      signature:
        <<0x6C, 0x2B, 0xC2, 0x8C, 0x45, 0x2B, 0x54, 0xF1, 0xC3, 0x59, 0x72, 0x3B, 0xE3, 0x19,
          0x1F, 0x55, 0x17, 0x25, 0x64, 0x0E, 0x65, 0x8C, 0x81, 0x0B>>
    }
  end

  defp corrupted_deck?(leaf_id, 0x054C, 0x0081) when byte_size(leaf_id) > 0 do
    leaf_id == :binary.copy(<<0xFF>>, byte_size(leaf_id))
  end

  defp corrupted_deck?(_leaf_id, _vendor_id, _product_id), do: false
end
