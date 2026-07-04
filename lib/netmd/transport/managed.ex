defmodule NetMD.Transport.Managed do
  @moduledoc """
  A `NetMD.Transport` that fronts another transport with a stable pid and
  transparent reconnection.

  NetMD portables re-enumerate on the USB bus whenever their state changes:
  inserting or ejecting a disc, powering on, or the `reset` that ends every
  session (`NetMD.Transport.Usb.close/1` mirrors netmd-js `finalize`, which
  resets). Each re-enumeration gives the device a new USB address and, beneath
  it, a new transfer engine with a new pid, so any handle held across the event
  goes stale.

  This transport hides that. `open/1` starts a manager process and returns its
  pid as the handle; the manager owns the real (base) transport handle and swaps
  in a fresh one when the device returns, so the handle a caller holds never
  changes. It is a drop-in `NetMD.Transport`, enabled by default from
  `NetMD.Device.open/1` (`reconnect: true`); pass `reconnect: false` for the
  bare `NetMD.Transport.Usb`.

  Reconnection is lazy: a dropped device is noticed when an operation fails, and
  that operation then blocks while the manager re-opens the same device (matched
  by vendor and product id) and is re-run on the new handle. So a caller's single
  call rides through a re-enumeration and succeeds, waiting up to `:reconnect_wait`
  before giving up with `{:error, :disconnected}`. No background polling happens
  while the device is idle.

  A physical re-enumeration resets the device, so protocol state that spans
  commands (a secure session, an in-progress TOC edit) does not survive it. Only
  the transport is restored, not device-side session state; re-run whole
  operations, not half of one.

  ## Status events

  Because the manager is a serial GenServer that already owns the device, it is
  the natural place to poll status and to serialise access. When given a
  `:status_fun` (`NetMD.Device.open/1` injects `NetMD.Commands.device_status/1`)
  it polls on a timer while at least one process is subscribed, and sends
  `{:netmd_status, status}` to subscribers whenever the reading changes. The poll
  runs inside one message handler, so it never interleaves with another manager
  message.

  A whole command/reply exchange spans several manager messages, though, so a
  poll must not land in the middle of one. `lock/1`/`unlock/1` (used by
  `NetMD.Device.with_lock/2`, which wraps `NetMD.Interface.send_query/3`) hold the
  device for an exchange; the poll defers while the lock is held. The lock is
  reentrant per process and released if its holder dies.

  Options (threaded through `NetMD.Device.open/1`):

    * `:reconnect_wait` - ms an operation waits for the device before returning
      `{:error, :disconnected}` (default `10_000`)
    * `:reconnect_poll` - ms between reopen attempts (default `500`)
    * `:base_transport` - transport to front (default `NetMD.Transport.Usb`)
    * `:status_event_poll` - ms between status polls, or `false` to disable
      (default `1000`)
    * `:status_fun` - 1-arity function read to poll status with; no polling
      without it
  """

  @behaviour NetMD.Transport
  use GenServer

  @default_reconnect_wait 10_000
  @default_reconnect_poll 500
  @default_status_poll 1000

  # Transfer errors (and a dead engine, mapped to :enodev) that mean the device
  # left the bus, as opposed to a recoverable transfer fault like :epipe.
  @disconnect_reasons [:enodev, :no_device, :enxio, :eshutdown, :closed]

  # ---- transport API (runs in the caller) --------------------------------

  @impl NetMD.Transport
  def open(opts \\ []) do
    base = Keyword.get(opts, :base_transport, NetMD.Transport.Usb)

    case GenServer.start(__MODULE__, {base, opts, self()}, []) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl NetMD.Transport
  def close(pid) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @impl NetMD.Transport
  def control_in(pid, request, value, index, length),
    do: call(pid, {:control_in, [request, value, index, length]})

  @impl NetMD.Transport
  def control_out(pid, request, value, index, data),
    do: call(pid, {:control_out, [request, value, index, data]})

  @impl NetMD.Transport
  def bulk_in(pid, length, timeout), do: call(pid, {:bulk_in, [length, timeout]})

  @impl NetMD.Transport
  def bulk_out(pid, data, timeout), do: call(pid, {:bulk_out, [data, timeout]})

  @impl NetMD.Transport
  def list(opts \\ []) do
    base = Keyword.get(opts, :base_transport, NetMD.Transport.Usb)
    if function_exported?(base, :list, 1), do: base.list(opts), else: []
  end

  # ---- status events and locking (run in the caller) ---------------------

  @doc "Subscribe `pid` (default caller) to `{:netmd_status, status}` events."
  @spec subscribe(pid(), pid()) :: :ok
  def subscribe(manager, pid \\ self()) when is_pid(pid),
    do: GenServer.call(manager, {:subscribe, pid})

  @doc "Stop `pid` (default caller) receiving status events."
  @spec unsubscribe(pid(), pid()) :: :ok
  def unsubscribe(manager, pid \\ self()) when is_pid(pid),
    do: GenServer.call(manager, {:unsubscribe, pid})

  @doc "Hold the device for one exchange. Reentrant per process; blocks until granted."
  @spec lock(pid()) :: :ok | :error
  def lock(manager), do: lock_call(manager, :lock)

  @doc "Release one level of the device lock."
  @spec unlock(pid()) :: :ok | :error
  def unlock(manager), do: lock_call(manager, :unlock)

  defp lock_call(manager, message) do
    GenServer.call(manager, message, :infinity)
  catch
    :exit, _ -> :error
  end

  # An op waits as long as the manager needs (it enforces :reconnect_wait), and a
  # dead manager becomes a plain error rather than crashing the caller.
  defp call(pid, op) do
    GenServer.call(pid, {:op, op}, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  # ---- server ------------------------------------------------------------

  @impl GenServer
  def init({base, opts, owner}) do
    # Trap exits: the base engine is linked here (CircuitsUsb.open uses
    # start_link), so its death must arrive as a message, not kill the manager.
    Process.flag(:trap_exit, true)

    case base.open(opts) do
      {:ok, handle, info} ->
        state = %{
          base: base,
          handle: handle,
          info: info,
          open_opts: reopen_opts(opts, info),
          status: :connected,
          waiters: [],
          deadline: nil,
          reconnect_wait: Keyword.get(opts, :reconnect_wait, @default_reconnect_wait),
          reconnect_poll: Keyword.get(opts, :reconnect_poll, @default_reconnect_poll),
          owner_ref: Process.monitor(owner),
          status_fun: Keyword.get(opts, :status_fun),
          poll_interval: poll_interval(opts),
          subscribers: MapSet.new(),
          last_status: nil,
          lock_owner: nil,
          lock_count: 0,
          lock_ref: nil,
          lock_waiters: :queue.new()
        }

        {:ok, schedule_poll(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp poll_interval(opts) do
    case Keyword.get(opts, :status_event_poll, @default_status_poll) do
      false -> nil
      ms when is_integer(ms) and ms > 0 -> ms
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  # Test/introspection hook: :connected | :reconnecting | :disconnected.
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:subscribe, pid}, _from, state) do
    if not MapSet.member?(state.subscribers, pid), do: Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}

  def handle_call(:lock, {pid, _}, %{lock_owner: nil} = state) do
    {:reply, :ok, %{state | lock_owner: pid, lock_count: 1, lock_ref: Process.monitor(pid)}}
  end

  def handle_call(:lock, {pid, _}, %{lock_owner: pid} = state),
    do: {:reply, :ok, %{state | lock_count: state.lock_count + 1}}

  def handle_call(:lock, from, state),
    do: {:noreply, %{state | lock_waiters: :queue.in(from, state.lock_waiters)}}

  def handle_call(:unlock, {pid, _}, %{lock_owner: pid, lock_count: count} = state)
      when count > 1,
      do: {:reply, :ok, %{state | lock_count: count - 1}}

  def handle_call(:unlock, {pid, _}, %{lock_owner: pid} = state) do
    Process.demonitor(state.lock_ref, [:flush])
    {:reply, :ok, grant_next_lock(%{state | lock_owner: nil, lock_count: 0, lock_ref: nil})}
  end

  def handle_call(:unlock, _from, state), do: {:reply, :ok, state}

  def handle_call({:op, op}, from, %{status: :connected} = state) do
    case run(state, op) do
      {:error, reason} when reason in @disconnect_reasons ->
        {:noreply, enqueue(begin_reconnect(state), from, op)}

      result ->
        {:reply, result, state}
    end
  end

  # Device is away; defer until it returns (or reconnect_wait elapses).
  def handle_call({:op, op}, from, state),
    do: {:noreply, enqueue(ensure_reconnecting(state), from, op)}

  @impl GenServer
  def handle_info(:reconnect, %{status: :reconnecting} = state) do
    case state.base.open(state.open_opts) do
      {:ok, handle, info} ->
        {:noreply,
         flush(%{state | handle: handle, info: info, status: :connected, deadline: nil})}

      {:error, _reason} ->
        if now_ms() >= state.deadline do
          {:noreply, %{fail(state, {:error, :disconnected}) | status: :disconnected}}
        else
          Process.send_after(self(), :reconnect, state.reconnect_poll)
          {:noreply, state}
        end
    end
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  def handle_info(:poll, state), do: {:noreply, schedule_poll(poll_now(state))}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      # The owner went away without closing; release the device.
      ref == state.owner_ref ->
        {:stop, :normal, state}

      # The lock holder died mid-exchange; release so others (and the poll) proceed.
      ref == state.lock_ref ->
        {:noreply, grant_next_lock(%{state | lock_owner: nil, lock_count: 0, lock_ref: nil})}

      # A subscriber exited.
      true ->
        {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
    end
  end

  # The base engine died under us (device yanked). Drop to disconnected and let
  # the next operation drive reconnection, rather than polling an idle device.
  def handle_info({:EXIT, pid, reason}, %{handle: pid, status: :connected} = state)
      when reason != :normal,
      do: {:noreply, %{state | status: :disconnected, handle: nil}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    safe_close(state.base, state.handle)
    :ok
  end

  # ---- internals ---------------------------------------------------------

  defp schedule_poll(%{status_fun: nil} = state), do: state
  defp schedule_poll(%{poll_interval: nil} = state), do: state

  defp schedule_poll(state) do
    Process.send_after(self(), :poll, state.poll_interval)
    state
  end

  # Read status on the base device inside this handler, so it is atomic against
  # every other manager message. Skip while disconnected, locked by a caller
  # mid-exchange, or with nobody listening. Emit only when the reading changes.
  defp poll_now(%{status: :connected, lock_owner: nil, status_fun: fun} = state)
       when is_function(fun, 1) do
    if MapSet.size(state.subscribers) == 0 do
      state
    else
      bare = %NetMD.Device{transport: state.base, handle: state.handle}

      case safe_status(fun, bare) do
        {:ok, status} when status != state.last_status ->
          broadcast(state.subscribers, {:netmd_status, status})
          %{state | last_status: status}

        _ ->
          state
      end
    end
  end

  defp poll_now(state), do: state

  defp safe_status(fun, bare) do
    fun.(bare)
  rescue
    error -> {:error, error}
  catch
    :exit, _ -> {:error, :exit}
  end

  defp broadcast(subscribers, message), do: Enum.each(subscribers, &send(&1, message))

  defp grant_next_lock(state) do
    case :queue.out(state.lock_waiters) do
      {{:value, {pid, _} = from}, rest} ->
        GenServer.reply(from, :ok)

        %{
          state
          | lock_owner: pid,
            lock_count: 1,
            lock_ref: Process.monitor(pid),
            lock_waiters: rest
        }

      {:empty, _} ->
        state
    end
  end

  defp run(%{base: base, handle: handle}, {fun, args}) do
    apply(base, fun, [handle | args])
  catch
    # A GenServer.call to a dead transfer engine: treat as a disconnect.
    :exit, _ -> {:error, :enodev}
  end

  defp begin_reconnect(%{status: :connected} = state) do
    safe_close(state.base, state.handle)
    send(self(), :reconnect)
    %{state | status: :reconnecting, handle: nil, deadline: now_ms() + state.reconnect_wait}
  end

  defp ensure_reconnecting(%{status: :disconnected} = state) do
    send(self(), :reconnect)
    %{state | status: :reconnecting, deadline: now_ms() + state.reconnect_wait}
  end

  defp ensure_reconnecting(state), do: state

  defp enqueue(state, from, op), do: %{state | waiters: state.waiters ++ [{from, op}]}

  # Re-run each deferred op on the fresh handle in order. If the device drops
  # again mid-flush, keep the current and remaining waiters and reconnect anew.
  defp flush(%{waiters: []} = state), do: state

  defp flush(%{status: :connected, waiters: [{from, op} | rest]} = state) do
    case run(state, op) do
      {:error, reason} when reason in @disconnect_reasons ->
        begin_reconnect(%{state | waiters: [{from, op} | rest]})

      result ->
        GenServer.reply(from, result)
        flush(%{state | waiters: rest})
    end
  end

  defp fail(state, reply) do
    Enum.each(state.waiters, fn {from, _op} -> GenServer.reply(from, reply) end)
    %{state | waiters: []}
  end

  # Reconnect targets the same model; a device that opened as "any known" is
  # pinned to the id it turned out to be so a second NetMD cannot be grabbed.
  defp reopen_opts(opts, info) do
    opts
    |> Keyword.put(:vendor_id, info.vendor_id)
    |> Keyword.put(:product_id, info.product_id)
  end

  defp safe_close(_base, nil), do: :ok

  defp safe_close(base, handle) do
    try do
      base.close(handle)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
