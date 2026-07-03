defmodule Netmd.MockTransport do
  @moduledoc """
  Scripted `Netmd.Transport` for tests.

  A script is a list of `{expected_call, response}` steps consumed in
  order. Expected calls:

      {:control_in, request, length}
      {:control_out, request, data}
      {:bulk_in, length}
      {:bulk_out, data}

  Start it with `start_script/1` and pass the pid as the `:script` option
  to `Netmd.Device.open/1` together with `transport: Netmd.MockTransport`.
  """

  @behaviour Netmd.Transport

  @type step :: {tuple(), term()}

  @spec start_script([step()]) :: {:ok, pid()}
  def start_script(steps) do
    Agent.start_link(fn -> steps end)
  end

  @spec remaining(pid()) :: [step()]
  def remaining(pid), do: Agent.get(pid, & &1)

  @impl Netmd.Transport
  def open(opts) do
    pid = Keyword.fetch!(opts, :script)

    info = %{
      vendor_id: Keyword.get(opts, :vendor_id, 0x054C),
      product_id: Keyword.get(opts, :product_id, 0x00C8)
    }

    {:ok, pid, info}
  end

  @impl Netmd.Transport
  def close(_pid), do: :ok

  @impl Netmd.Transport
  def control_in(pid, request, _value, _index, length) do
    respond(pid, {:control_in, request, length})
  end

  @impl Netmd.Transport
  def control_out(pid, request, _value, _index, data) do
    respond(pid, {:control_out, request, data})
  end

  @impl Netmd.Transport
  def bulk_in(pid, length, _timeout) do
    respond(pid, {:bulk_in, length})
  end

  @impl Netmd.Transport
  def bulk_out(pid, data, _timeout) do
    respond(pid, {:bulk_out, data})
  end

  defp respond(pid, call) do
    step =
      Agent.get_and_update(pid, fn
        [] -> {:empty, []}
        [next | rest] -> {next, rest}
      end)

    case step do
      :empty ->
        raise "mock transport got #{inspect(call)} but the script is exhausted"

      {^call, response} ->
        response

      {expected, _response} ->
        raise "mock transport expected #{inspect(expected)} but got #{inspect(call)}"
    end
  end
end
