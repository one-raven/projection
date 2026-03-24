defmodule ProjectionUI.AsyncResult do
  @moduledoc """
  Represents the state of an asynchronous operation.

  Used with `ProjectionUI.State.async_assign/3` to track loading, success,
  and failure states for async data fetches.

  ## Fields

    * `:loading` — `true` while the async operation is in progress
    * `:ok?` — `true` when the operation has completed successfully
    * `:result` — the successful result value (nil until ok)
    * `:failed` — the failure reason (nil unless failed)

  ## Example

      # In a screen mount:
      def mount(_params, _session, state) do
        {:ok, async_assign(state, :data, fn -> fetch_data() end)}
      end

      # In render, pattern match on the result:
      def render(assigns) do
        data = assigns.data
        %{
          loading: data.loading,
          content: if(data.ok?, do: inspect(data.result), else: ""),
          error: if(data.failed, do: inspect(data.failed), else: "")
        }
      end
  """

  defstruct loading: false, ok?: false, result: nil, failed: nil

  @type t :: %__MODULE__{
          loading: boolean(),
          ok?: boolean(),
          result: any(),
          failed: any()
        }

  @doc "Returns an AsyncResult in the loading state."
  @spec loading() :: t()
  def loading, do: %__MODULE__{loading: true}

  @doc "Returns an AsyncResult in the success state with the given result."
  @spec ok(any()) :: t()
  def ok(result), do: %__MODULE__{ok?: true, result: result}

  @doc "Returns an AsyncResult in the failed state with the given reason."
  @spec failed(any()) :: t()
  def failed(reason), do: %__MODULE__{failed: reason}
end
