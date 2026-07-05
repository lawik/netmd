defmodule NetMD.Simulator.Gadget do
  @moduledoc """
  Present the `NetMD.Simulator` brain as a real USB NetMD device.

  Where `NetMD.Simulator` implements a `NetMD.Transport` for in-process
  use, this wires the same device brain to a Linux USB gadget over
  `BodgeUSBGadget` and `BodgeUSBGadget.FunctionFs`. The vendor control
  protocol (reply-length poll, command, read-reply, factory) arrives as
  FunctionFS SETUP events; the bulk OUT endpoint (track download) is read
  by a task. The result is an actual USB device on the bus.

  With `dummy_hcd` loaded, the gadget and a host driving it with the real
  `NetMD.Transport.Usb` can run in the same machine, so the whole stack is
  exercised over usbfs without any external hardware. This is the "both
  sides in one VM" setup; see `vm/` and `README_VM.md`.

  ## Requirements (root)

  configfs and functionfs mounted, `libcomposite` and `usb_f_fs` loaded, a
  UDC available (`dummy_hcd` provides `dummy_udc.0`). It does nothing
  useful off a Linux gadget host, so it is not started by the library.

  ## Use

      {:ok, g} = NetMD.Simulator.Gadget.start_link(udc: "dummy_udc.0")
      # ... a host now enumerates a Sony NetMD device and can be driven
      # with NetMD.open() (real transport) from another process/VM ...
      :ok = NetMD.Simulator.Gadget.stop(g)

  Pass `disc:` to start from a custom `NetMD.Simulator.Disc`.
  """

  use GenServer

  alias BodgeUSBGadget, as: Gadget
  alias BodgeUSBGadget.FunctionFs
  alias NetMD.Simulator

  require Logger

  # NetMD endpoints: bulk OUT 0x02 (host writes track data), bulk IN 0x81
  # (device sends, for uploads). Declared OUT-first so ep1 is the OUT file.
  @bulk_out_ep 0x02
  @bulk_in_ep 0x81
  @bulk_out_index 1

  @default_gadget "netmd"
  @default_instance "netmd"
  @default_mountpoint "/dev/ffs-netmd"
  @bulk_chunk 0x10000

  @doc """
  Start the gadget. Options:

    * `:disc` - a `NetMD.Simulator.Disc` to present (default: demo disc)
    * `:vendor_id` / `:product_id` - USB ids (default Sony MZ-N710)
    * `:udc` - the UDC to bind to (default: first in `/sys/class/udc`)
    * `:gadget` / `:instance` / `:mountpoint` - naming overrides
    * `:name` - register the GenServer under a name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Tear the gadget down (unbind, remove, unmount) and stop the brain."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @doc "The device brain process, for inspecting or seeding disc state."
  @spec brain(GenServer.server()) :: pid()
  def brain(server), do: GenServer.call(server, :brain)

  ## Server

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = %{
      gadget: Keyword.get(opts, :gadget, @default_gadget),
      instance: Keyword.get(opts, :instance, @default_instance),
      mountpoint: Keyword.get(opts, :mountpoint, @default_mountpoint),
      vendor_id: Keyword.get(opts, :vendor_id, 0x054C),
      product_id: Keyword.get(opts, :product_id, 0x00C8),
      udc: Keyword.get(opts, :udc)
    }

    with {:ok, brain} <-
           Simulator.start_link(Keyword.take(opts, [:disc, :vendor_id, :product_id])),
         {:ok, gadget} <- define_gadget(config),
         :ok <- FunctionFs.mount(config.instance, config.mountpoint),
         {:ok, ffs} <- start_function(config, brain),
         :ok <- bind(gadget, config.udc) do
      {:ok,
       %{
         config: config,
         brain: brain,
         gadget: gadget,
         ffs: ffs,
         bulk_task: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:brain, _from, state), do: {:reply, state.brain, state}

  @impl GenServer
  def handle_info({:functionfs, _server, :enabled}, state) do
    # The host configured the device; endpoints are live. Start reading the
    # bulk OUT endpoint so track downloads reach the brain.
    {:noreply, %{state | bulk_task: start_bulk_reader(state)}}
  end

  def handle_info({:functionfs, _server, event}, state) when event in [:disabled, :unbound] do
    {:noreply, %{state | bulk_task: stop_bulk_reader(state.bulk_task)}}
  end

  def handle_info({:functionfs, _server, _event}, state), do: {:noreply, state}

  def handle_info({ref, _result}, %{bulk_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | bulk_task: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # Only a crash of the brain or the FunctionFS server is fatal. Ignore EXIT
  # signals from transient ports (the mount/umount commands run via
  # System.cmd) and other short-lived linked helpers, which would otherwise
  # tear the gadget down the moment it comes up.
  def handle_info({:EXIT, pid, reason}, state) do
    if pid in [state.brain, state.ffs] do
      {:stop, reason, state}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = stop_bulk_reader(state.bulk_task)
    _ = if state.ffs, do: FunctionFs.stop(state.ffs)
    _ = Gadget.unbind(state.gadget)
    _ = Gadget.remove(state.gadget)
    _ = FunctionFs.umount(state.config.mountpoint)
    _ = if Process.alive?(state.brain), do: Simulator.close(state.brain)
    :ok
  end

  ## Setup helpers

  defp define_gadget(config) do
    Gadget.define(config.gadget, %{
      vendor_id: config.vendor_id,
      product_id: config.product_id,
      strings: %{
        manufacturer: "Sony",
        product: "NetMD Simulator",
        serialnumber: "SIM-0001"
      },
      functions: %{"ffs.#{config.instance}" => %{}},
      configs: %{
        "c.1" => %{configuration: "NetMD", max_power: 100, functions: ["ffs.#{config.instance}"]}
      }
    })
  end

  defp start_function(config, brain) do
    FunctionFs.start_link(
      mountpoint: config.mountpoint,
      notify: self(),
      strings: ["NetMD"],
      function: %{
        interface: %{class: 0xFF, subclass: 0, protocol: 0, string_index: 1},
        endpoints: [
          %{address: @bulk_out_ep, type: :bulk},
          %{address: @bulk_in_ep, type: :bulk}
        ],
        flags: [:all_ctrl_recip]
      },
      handler: control_handler(brain)
    )
  end

  defp bind(gadget, nil), do: Gadget.bind(gadget)
  defp bind(gadget, udc), do: Gadget.bind(gadget, udc)

  # Translate a control SETUP into a brain call. IN requests reply with the
  # brain's data; OUT requests hand the payload to the brain.
  defp control_handler(brain) do
    fn setup, data ->
      if setup.request_type >= 0x80 do
        {:ok, reply} =
          Simulator.control_in(brain, setup.request, setup.value, setup.index, setup.length)

        {:reply, reply}
      else
        :ok = Simulator.control_out(brain, setup.request, setup.value, setup.index, data)
        :ok
      end
    end
  end

  ## Bulk OUT reader

  defp start_bulk_reader(state) do
    mountpoint = state.config.mountpoint
    brain = state.brain

    Task.async(fn -> read_bulk_out(mountpoint, brain) end)
  end

  defp stop_bulk_reader(nil), do: nil

  defp stop_bulk_reader(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    nil
  end

  defp read_bulk_out(mountpoint, brain) do
    case FunctionFs.open_endpoint(mountpoint, @bulk_out_index) do
      {:ok, endpoint} ->
        bulk_loop(endpoint, brain)
        FunctionFs.close_endpoint(endpoint)

      {:error, reason} ->
        Logger.warning("NetMD.Simulator.Gadget: bulk OUT open failed: #{inspect(reason)}")
    end
  end

  defp bulk_loop(endpoint, brain) do
    case FunctionFs.read(endpoint, @bulk_chunk) do
      {:ok, <<>>} ->
        :ok

      {:ok, data} ->
        :ok = Simulator.bulk_out(brain, data, :infinity)
        bulk_loop(endpoint, brain)

      # The host disconnected or the gadget unbound; stop quietly.
      {:error, _reason} ->
        :ok
    end
  end
end
