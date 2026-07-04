defmodule NetMD.Devices do
  @moduledoc """
  Known NetMD USB devices, from the netmd-js device table.
  """

  @typedoc "Per-device quirk flags."
  @type flags :: %{optional(:native_mono_upload) => boolean()}

  @typedoc "A known device."
  @type device :: %{
          vendor_id: 0..0xFFFF,
          product_id: 0..0xFFFF,
          name: String.t(),
          flags: flags()
        }

  @mono %{native_mono_upload: true}

  # {vendor_id, product_id, name, flags}
  @table [
    {0x04DD, 0x7202, "Sharp IM-MT899H", %{}},
    {0x04DD, 0x9013, "Sharp IM-DR400", %{}},
    {0x04DD, 0x9014, "Sharp IM-DR80", @mono},
    {0x054C, 0x0034, "Sony PCLK-XX", %{}},
    {0x054C, 0x0036, "Sony", %{}},
    {0x054C, 0x0075, "Sony MZ-N1", %{}},
    {0x054C, 0x007C, "Sony", %{}},
    {0x054C, 0x0080, "Sony LAM-1", %{}},
    {0x054C, 0x0081, "Sony MDS-JB980/MDS-NT1/MDS-JE780", @mono},
    {0x054C, 0x0084, "Sony MZ-N505", %{}},
    {0x054C, 0x0085, "Sony MZ-S1", %{}},
    {0x054C, 0x0086, "Sony MZ-N707", %{}},
    {0x054C, 0x008E, "Sony CMT-C7NT", %{}},
    {0x054C, 0x0097, "Sony PCGA-MDN1", %{}},
    {0x054C, 0x00AD, "Sony CMT-L7HD", %{}},
    {0x054C, 0x00C6, "Sony MZ-N10", %{}},
    {0x054C, 0x00C7, "Sony MZ-N910", %{}},
    {0x054C, 0x00C8, "Sony MZ-N710/NF810", %{}},
    {0x054C, 0x00C9, "Sony MZ-N510/N610", %{}},
    {0x054C, 0x00CA, "Sony MZ-NE410/NF520D", %{}},
    {0x054C, 0x00E7, "Sony CMT-M333NT/M373NT", %{}},
    {0x054C, 0x00EB, "Sony MZ-NE810/NE910", %{}},
    {0x054C, 0x0101, "Sony LAM", %{}},
    {0x054C, 0x0113, "Aiwa AM-NX1", %{}},
    {0x054C, 0x011A, "Sony CMT-SE7", %{}},
    {0x054C, 0x013F, "Sony MDS-S500", %{}},
    {0x054C, 0x0148, "Sony MDS-A1", %{}},
    {0x054C, 0x014C, "Aiwa AM-NX9", %{}},
    {0x054C, 0x017E, "Sony MZ-NH1", %{}},
    {0x054C, 0x0180, "Sony MZ-NH3D", %{}},
    {0x054C, 0x0182, "Sony MZ-NH900", %{}},
    {0x054C, 0x0184, "Sony MZ-NH700/NH800", %{}},
    {0x054C, 0x0186, "Sony MZ-NH600", %{}},
    {0x054C, 0x0187, "Sony MZ-NH600D", %{}},
    {0x054C, 0x0188, "Sony MZ-N920", %{}},
    {0x054C, 0x018A, "Sony LAM-3", %{}},
    {0x054C, 0x01E9, "Sony MZ-DH10P", %{}},
    {0x054C, 0x0219, "Sony MZ-RH10", %{}},
    {0x054C, 0x021B, "Sony MZ-RH710/MZ-RH910", %{}},
    {0x054C, 0x021D, "Sony CMT-AH10", %{}},
    {0x054C, 0x022C, "Sony CMT-AH10", %{}},
    {0x054C, 0x023C, "Sony DS-HMD1", %{}},
    {0x054C, 0x0286, "Sony MZ-RH1", %{}},
    {0x0B28, 0x1004, "Kenwood MDX-J9", %{}},
    {0x04DA, 0x23B3, "Panasonic SJ-MR250", @mono},
    {0x04DA, 0x23B6, "Panasonic SJ-MR270", @mono},
    {0x0411, 0x0083, "Buffalo MD-HUSB", %{}}
  ]

  @doc "All known devices."
  @spec all() :: [device()]
  def all() do
    for {vendor_id, product_id, name, flags} <- @table do
      %{vendor_id: vendor_id, product_id: product_id, name: name, flags: flags}
    end
  end

  @doc "Look up a device by USB ids."
  @spec find(0..0xFFFF, 0..0xFFFF) :: {:ok, device()} | :error
  def find(vendor_id, product_id) do
    case Enum.find(all(), &(&1.vendor_id == vendor_id and &1.product_id == product_id)) do
      nil -> :error
      device -> {:ok, device}
    end
  end

  @doc "Whether the USB ids belong to a known NetMD device."
  @spec known?(0..0xFFFF, 0..0xFFFF) :: boolean()
  def known?(vendor_id, product_id), do: match?({:ok, _}, find(vendor_id, product_id))

  @doc "Device display name, `\"Unknown Device\"` if not in the table."
  @spec name(0..0xFFFF, 0..0xFFFF) :: String.t()
  def name(vendor_id, product_id) do
    case find(vendor_id, product_id) do
      {:ok, %{name: name}} -> name
      :error -> "Unknown Device"
    end
  end

  @doc "Quirk flags for a device, empty map if not in the table."
  @spec flags(0..0xFFFF, 0..0xFFFF) :: flags()
  def flags(vendor_id, product_id) do
    case find(vendor_id, product_id) do
      {:ok, %{flags: flags}} -> flags
      :error -> %{}
    end
  end
end
