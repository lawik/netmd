defmodule NetMD.Transport.Usb do
  @moduledoc """
  `NetMD.Transport` backed by `BodgeUSB`.

  Opens the first known NetMD device (or an explicit `:vendor_id` and
  `:product_id`), detaches any kernel driver and claims interface 0. The
  endpoints match every known NetMD device: bulk IN `0x81`, bulk OUT `0x02`.

  `list/1` enumerates every connected known NetMD device without opening any.
  """

  @behaviour NetMD.Transport

  alias BodgeUSB.Descriptor
  alias NetMD.Devices

  # bmRequestType: vendor type, interface recipient
  @request_type_out 0x41
  @request_type_in 0xC1

  @bulk_in_endpoint 0x81
  @bulk_out_endpoint 0x02
  @interface 0
  @control_timeout 1000

  @impl NetMD.Transport
  def open(opts \\ []) do
    with {:ok, ref, info} <- find(opts),
         {:ok, device} <- BodgeUSB.open(ref) do
      _ = BodgeUSB.detach_driver(device, @interface)

      case BodgeUSB.claim_interface(device, @interface) do
        :ok ->
          {:ok, device, info}

        {:error, reason} ->
          BodgeUSB.close(device)
          {:error, reason}
      end
    end
  end

  @impl NetMD.Transport
  def close(device) do
    _ = BodgeUSB.reset(device)
    _ = BodgeUSB.release_interface(device, @interface)
    BodgeUSB.close(device)
  end

  @impl NetMD.Transport
  def control_in(device, request, value, index, length) do
    BodgeUSB.control_transfer(
      device,
      @request_type_in,
      request,
      value,
      index,
      length,
      @control_timeout
    )
  end

  @impl NetMD.Transport
  def control_out(device, request, value, index, data) do
    case BodgeUSB.control_transfer(
           device,
           @request_type_out,
           request,
           value,
           index,
           data,
           @control_timeout
         ) do
      {:ok, _written} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl NetMD.Transport
  def bulk_in(device, length, timeout) do
    BodgeUSB.bulk_in(device, @bulk_in_endpoint, length, timeout)
  end

  @impl NetMD.Transport
  def bulk_out(device, data, timeout) do
    case BodgeUSB.bulk_out(device, @bulk_out_endpoint, data, timeout) do
      {:ok, _written} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl NetMD.Transport
  def list(_opts \\ []) do
    for ref <- BodgeUSB.list_devices(),
        {:ok, %Descriptor.Device{vendor_id: vendor_id, product_id: product_id}} <-
          [ref.descriptor],
        Devices.known?(vendor_id, product_id) do
      %{
        vendor_id: vendor_id,
        product_id: product_id,
        bus: ref.bus,
        address: ref.address
      }
    end
  end

  defp find(opts) do
    wanted =
      case {Keyword.get(opts, :vendor_id), Keyword.get(opts, :product_id)} do
        {nil, _} -> :any_known
        {_, nil} -> :any_known
        {vendor_id, product_id} -> {vendor_id, product_id}
      end

    case Enum.find_value(BodgeUSB.list_devices(), &match_ref(&1, wanted)) do
      nil -> {:error, :not_found}
      {ref, info} -> {:ok, ref, info}
    end
  end

  defp match_ref(ref, wanted) do
    case ref.descriptor do
      {:ok, %Descriptor.Device{vendor_id: vendor_id, product_id: product_id}} ->
        if wanted?(wanted, vendor_id, product_id) do
          {ref, %{vendor_id: vendor_id, product_id: product_id}}
        end

      _ ->
        nil
    end
  end

  defp wanted?(:any_known, vendor_id, product_id), do: Devices.known?(vendor_id, product_id)
  defp wanted?({vendor_id, product_id}, vendor_id, product_id), do: true
  defp wanted?(_wanted, _vendor_id, _product_id), do: false
end
