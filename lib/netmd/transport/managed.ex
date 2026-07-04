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

  Options (threaded through `NetMD.Device.open/1`):

    * `:reconnect_wait` - ms an operation waits for the device before returning
      `{:error, :disconnected}` (default `10_000`)
    * `:reconnect_poll` - ms between reopen attempts (default `500`)
    * `:base_transport` - transport to front (default `NetMD.Transport.Usb`)
  """

  @behaviour NetMD.Transport
  use GenServer

  @default_reconnect_wait 10_000
  @default_reconnect_poll 500

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
        Process.monitor(owner)

        {:ok,
         %{
           base: base,
           handle: handle,
           info: info,
           open_opts: reopen_opts(opts, info),
           status: :connected,
           waiters: [],
           deadline: nil,
           reconnect_wait: Keyword.get(opts, :reconnect_wait, @default_reconnect_wait),
           reconnect_poll: Keyword.get(opts, :reconnect_poll, @default_reconnect_poll)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  # Test/introspection hook: :connected | :reconnecting | :disconnected.
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

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

  # The owner went away without closing; release the device.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

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
