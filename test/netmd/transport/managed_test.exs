defmodule NetMD.Transport.ManagedTest do
  use ExUnit.Case, async: true

  alias NetMD.Transport.Managed

  # A base transport whose connectedness is flipped through an Agent, so a test
  # can simulate the device leaving and returning on the bus.
  defmodule Fake do
    @behaviour NetMD.Transport

    @impl true
    def open(opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get_and_update(agent, fn s ->
        if s.connected do
          {{:ok, {agent}, %{vendor_id: 0x054C, product_id: 0x0086}}, %{s | opens: s.opens + 1}}
        else
          {{:error, :not_found}, s}
        end
      end)
    end

    @impl true
    def close(_handle), do: :ok

    @impl true
    def control_in({agent}, _request, _value, _index, length),
      do: guarded(agent, {:ok, :binary.copy(<<0>>, length)})

    @impl true
    def control_out({agent}, _request, _value, _index, _data), do: guarded(agent, :ok)

    @impl true
    def bulk_in({agent}, length, _timeout),
      do: guarded(agent, {:ok, :binary.copy(<<0>>, length)})

    @impl true
    def bulk_out({agent}, _data, _timeout), do: guarded(agent, :ok)

    defp guarded(agent, ok) do
      if Agent.get(agent, & &1.connected), do: ok, else: {:error, :enodev}
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{connected: true, opens: 0} end)
    %{agent: agent}
  end

  defp connect(agent), do: Agent.update(agent, &%{&1 | connected: true})
  defp disconnect(agent), do: Agent.update(agent, &%{&1 | connected: false})
  defp opens(agent), do: Agent.get(agent, & &1.opens)

  defp open(agent, opts \\ []) do
    Managed.open([base_transport: Fake, agent: agent] ++ opts)
  end

  defp wait_status(pid, status, tries \\ 200)
  defp wait_status(_pid, status, 0), do: flunk("never reached status #{status}")

  defp wait_status(pid, status, tries) do
    unless GenServer.call(pid, :status) == status do
      Process.sleep(5)
      wait_status(pid, status, tries - 1)
    end
  end

  test "open returns a stable pid handle and the device info", %{agent: agent} do
    assert {:ok, pid, info} = open(agent)
    assert is_pid(pid)
    assert info == %{vendor_id: 0x054C, product_id: 0x0086}
    assert Managed.control_in(pid, 1, 0, 0, 4) == {:ok, <<0, 0, 0, 0>>}
  end

  test "open surfaces a base failure without crashing the caller", %{agent: agent} do
    disconnect(agent)
    assert open(agent) == {:error, :not_found}
    assert Process.alive?(self())
  end

  test "an operation rides through a re-enumeration on the same pid", %{agent: agent} do
    {:ok, pid, _info} = open(agent, reconnect_wait: 2000, reconnect_poll: 10)

    # Device leaves the bus; the in-flight op blocks while the manager retries.
    disconnect(agent)
    task = Task.async(fn -> Managed.control_in(pid, 1, 0, 0, 4) end)
    wait_status(pid, :reconnecting)

    # Device returns; the deferred op runs on the fresh handle and succeeds.
    connect(agent)
    assert Task.await(task, 3000) == {:ok, <<0, 0, 0, 0>>}

    assert Process.alive?(pid), "the handle pid must not change across a reconnect"
    assert opens(agent) == 2, "the manager should have re-opened the base device"
    assert GenServer.call(pid, :status) == :connected
  end

  test "an operation gives up with :disconnected past reconnect_wait", %{agent: agent} do
    {:ok, pid, _info} = open(agent, reconnect_wait: 80, reconnect_poll: 10)

    disconnect(agent)
    assert Managed.control_in(pid, 1, 0, 0, 4) == {:error, :disconnected}

    # Still alive, and it recovers once the device returns.
    assert Process.alive?(pid)
    connect(agent)
    assert Managed.control_in(pid, 1, 0, 0, 4) == {:ok, <<0, 0, 0, 0>>}
  end

  test "closing stops the manager and releases the base device", %{agent: agent} do
    {:ok, pid, _info} = open(agent)
    ref = Process.monitor(pid)
    assert Managed.close(pid) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  test "the manager releases the device when its owner dies", %{agent: agent} do
    test = self()

    owner =
      spawn(fn ->
        {:ok, pid, _info} = open(agent)
        send(test, {:pid, pid})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:pid, pid}
    mref = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^mref, :process, ^pid, _}
  end

  test "the lock is reentrant for its holder and exclusive to others", %{agent: agent} do
    {:ok, pid, _info} = open(agent)
    parent = self()

    assert Managed.lock(pid) == :ok
    # Reentrant: the same process can take it again without blocking.
    assert Managed.lock(pid) == :ok

    other = Task.async(fn -> send(parent, {:acquired, Managed.lock(pid)}) end)
    refute_receive {:acquired, _}, 100, "another process must block while the lock is held"

    # One unlock leaves it held (reentrant depth 2 -> 1).
    assert Managed.unlock(pid) == :ok
    refute_receive {:acquired, _}, 50

    # Fully released; the waiter is granted the lock.
    assert Managed.unlock(pid) == :ok
    assert_receive {:acquired, :ok}, 500
    Task.await(other)
  end

  test "a dead lock holder releases the lock", %{agent: agent} do
    {:ok, pid, _info} = open(agent)
    parent = self()

    holder =
      spawn(fn ->
        Managed.lock(pid)
        send(parent, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held

    waiter = Task.async(fn -> send(parent, {:acquired, Managed.lock(pid)}) end)
    refute_receive {:acquired, _}, 100

    Process.exit(holder, :kill)
    assert_receive {:acquired, :ok}, 500
    Task.await(waiter)
  end
end
