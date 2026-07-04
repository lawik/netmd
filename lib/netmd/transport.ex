defmodule Netmd.Transport do
  @moduledoc """
  Behaviour for the USB plumbing underneath `Netmd.Device`.

  NetMD devices speak vendor-specific control transfers on the default
  endpoint plus one bulk IN and one bulk OUT endpoint. Implemented by
  `Netmd.Transport.Usb` for real hardware and by a scripted mock in the
  test suite.
  """

  @typedoc "Implementation-specific device handle."
  @type handle :: term()

  @typedoc "Identifying info returned from `c:open/1`."
  @type info :: %{vendor_id: 0..0xFFFF, product_id: 0..0xFFFF}

  @typedoc "A device found by `c:list/1`, located on the bus."
  @type location :: %{
          vendor_id: 0..0xFFFF,
          product_id: 0..0xFFFF,
          bus: pos_integer() | nil,
          address: pos_integer() | nil
        }

  @doc "Open a device, prepare it for I/O and return a handle plus info."
  @callback open(keyword()) :: {:ok, handle(), info()} | {:error, term()}

  @doc """
  List the connected NetMD devices without opening any of them.

  Enumeration is best-effort and does not fail: a device that cannot be read is
  simply left out. Optional; transports that model a single fixed device need
  not implement it.
  """
  @callback list(keyword()) :: [location()]

  @optional_callbacks list: 1

  @doc "Release the device."
  @callback close(handle()) :: :ok

  @doc "Vendor-interface control IN transfer."
  @callback control_in(
              handle(),
              request :: 0..255,
              value :: 0..0xFFFF,
              index :: 0..0xFFFF,
              length :: non_neg_integer()
            ) :: {:ok, binary()} | {:error, term()}

  @doc "Vendor-interface control OUT transfer."
  @callback control_out(
              handle(),
              request :: 0..255,
              value :: 0..0xFFFF,
              index :: 0..0xFFFF,
              data :: binary()
            ) :: :ok | {:error, term()}

  @doc "Read from the bulk IN endpoint."
  @callback bulk_in(handle(), length :: non_neg_integer(), timeout()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Write to the bulk OUT endpoint."
  @callback bulk_out(handle(), data :: binary(), timeout()) :: :ok | {:error, term()}
end
