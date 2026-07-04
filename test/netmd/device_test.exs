defmodule Netmd.DeviceTest do
  use ExUnit.Case, async: true

  alias Netmd.Device
  alias Netmd.MockTransport

  defp open!(script, opts \\ []) do
    {:ok, pid} = MockTransport.start_script(script)

    {:ok, device} =
      Device.open([transport: MockTransport, script: pid] ++ opts)

    {device, pid}
  end

  # No pending reply: open only polls once.
  @clean_poll {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}

  test "open drains a leftover reply like the reference init" do
    script = [
      # init poll finds 4 pending bytes
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 4, 0>>}},
      # read_reply polls again, then reads, then polls once more
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 4, 0>>}},
      {{:control_in, 0x81, 4}, {:ok, <<0x0A, 0xFF, 0xFF, 0xFF>>}},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}
    ]

    {device, pid} = open!(script)
    assert MockTransport.remaining(pid) == []
    assert Device.name(device) == "Sony MZ-N710/NF810"
  end

  test "send_command and read_reply exchange" do
    command = <<0x00, 0x18, 0x08, 0x10, 0x10, 0x00, 0x01, 0x00>>
    reply = <<0x09, 0x18, 0x08, 0x10, 0x10, 0x00, 0x01, 0x00>>

    script = [
      @clean_poll,
      {{:control_out, 0x80, command}, :ok},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 8, 0>>}},
      {{:control_in, 0x81, 8}, {:ok, reply}},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}
    ]

    {device, pid} = open!(script)
    assert :ok = Device.send_command(device, command)
    assert {:ok, ^reply} = Device.read_reply(device)
    assert MockTransport.remaining(pid) == []
  end

  test "read_reply polls with backoff until a length appears" do
    script = [
      @clean_poll,
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 2, 0>>}},
      {{:control_in, 0x81, 2}, {:ok, <<0x09, 0x00>>}},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}
    ]

    {device, pid} = open!(script)
    assert {:ok, <<0x09, 0x00>>} = Device.read_reply(device)
    assert MockTransport.remaining(pid) == []
  end

  test "read_reply gives up after max_polls" do
    polls = List.duplicate({{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}, 3)

    {:ok, pid} = MockTransport.start_script([@clean_poll | polls])

    {:ok, device} = Device.open(transport: MockTransport, script: pid)
    device = %{device | max_polls: 3, poll_interval_ms: 1}

    assert {:error, :no_reply} = Device.read_reply(device)
    assert MockTransport.remaining(pid) == []
  end

  test "factory commands use request 0xff" do
    script = [
      @clean_poll,
      {{:control_out, 0xFF, <<0x01>>}, :ok},
      {{:control_in, 0xFF, 3}, {:ok, <<1, 2, 3>>}},
      {{:control_in, 0x01, 4}, {:ok, <<0, 0, 0, 0>>}}
    ]

    {device, pid} = open!(script)
    assert :ok = Device.send_command(device, <<0x01>>, factory?: true)
    assert {:ok, <<1, 2, 3>>} = Device.read_reply(device, factory?: true, length: 3)
    assert MockTransport.remaining(pid) == []
  end

  test "read_bulk chunks and reports progress" do
    script = [
      @clean_poll,
      {{:bulk_in, 2}, {:ok, <<1, 2>>}},
      {{:bulk_in, 2}, {:ok, <<3, 4>>}},
      {{:bulk_in, 1}, {:ok, <<5>>}}
    ]

    {device, pid} = open!(script)
    parent = self()

    assert {:ok, <<1, 2, 3, 4, 5>>} =
             Device.read_bulk(device, 5,
               chunk_size: 2,
               progress: fn total, done -> send(parent, {:progress, total, done}) end
             )

    assert_received {:progress, 5, 2}
    assert_received {:progress, 5, 4}
    assert_received {:progress, 5, 5}
    assert MockTransport.remaining(pid) == []
  end

  test "write_bulk passes data through" do
    script = [
      @clean_poll,
      {{:bulk_out, <<9, 9, 9>>}, :ok}
    ]

    {device, pid} = open!(script)
    assert :ok = Device.write_bulk(device, <<9, 9, 9>>)
    assert MockTransport.remaining(pid) == []
  end

  test "list enriches each device with its table name and flags" do
    devices = [
      %{vendor_id: 0x054C, product_id: 0x00C8, bus: 1, address: 4},
      %{vendor_id: 0x04DD, product_id: 0x9014, bus: 1, address: 7}
    ]

    assert [first, second] = Device.list(transport: MockTransport, devices: devices)

    assert first == %{
             vendor_id: 0x054C,
             product_id: 0x00C8,
             name: "Sony MZ-N710/NF810",
             flags: %{},
             bus: 1,
             address: 4
           }

    assert second.name == "Sharp IM-DR80"
    assert second.flags == %{native_mono_upload: true}
  end

  test "list returns an empty list when nothing is connected" do
    assert [] = Device.list(transport: MockTransport, devices: [])
  end

  test "list raises for a transport that cannot enumerate" do
    defmodule NoListTransport do
      @behaviour Netmd.Transport
      def open(_opts), do: {:error, :nope}
      def close(_), do: :ok
      def control_in(_, _, _, _, _), do: {:error, :nope}
      def control_out(_, _, _, _, _), do: {:error, :nope}
      def bulk_in(_, _, _), do: {:error, :nope}
      def bulk_out(_, _, _), do: {:error, :nope}
    end

    assert_raise ArgumentError, ~r/does not support listing/, fn ->
      Device.list(transport: NoListTransport)
    end
  end
end
