defmodule ProjectionUI.State do
  @moduledoc """
  Minimal screen-state struct and assign helpers used by Projection screen modules.

  This is not a network socket. It is a small container for screen assigns.
  """

  @missing_key :__projection_missing_key__

  @enforce_keys [:assigns, :changed]
  defstruct assigns: %{},
            changed: MapSet.new(),
            derived_fields: MapSet.new(),
            pending_async: []

  @type t :: %__MODULE__{
          assigns: map(),
          changed: MapSet.t(atom()),
          derived_fields: MapSet.t(atom()),
          pending_async: list()
        }

  @doc """
  Creates a new state with the given initial assigns.

  The change set starts empty — initial assigns are not marked as changed.
  """
  @spec new(map()) :: t()
  def new(assigns \\ %{}) when is_map(assigns) do
    %__MODULE__{assigns: assigns, changed: MapSet.new()}
  end

  @doc """
  Creates a new state with the given initial assigns and options.

  ## Options

    * `:derived` — list of field names that are derived (cannot be directly assigned)
  """
  @spec new(map(), keyword()) :: t()
  def new(assigns, opts) when is_map(assigns) and is_list(opts) do
    derived_fields =
      opts
      |> Keyword.get(:derived, [])
      |> MapSet.new()

    %__MODULE__{assigns: assigns, changed: MapSet.new(), derived_fields: derived_fields}
  end

  @doc """
  Sets `key` to `value` in the state's assigns.

  If `value` is identical (`===`) to the current value, the state is returned
  unchanged and the key is **not** marked as changed.

  Raises `ArgumentError` if `key` is a derived field.
  """
  @spec assign(t(), atom(), any()) :: t()
  def assign(%__MODULE__{} = state, key, value) when is_atom(key) do
    if MapSet.member?(state.derived_fields, key) do
      raise ArgumentError, "cannot directly assign derived field #{inspect(key)}"
    end

    current = Map.get(state.assigns, key, @missing_key)

    if current === value do
      state
    else
      %{
        state
        | assigns: Map.put(state.assigns, key, value),
          changed: MapSet.put(state.changed, key)
      }
    end
  end

  @doc "Applies `fun` to the current value of `key` and assigns the result."
  @spec update(t(), atom(), (any() -> any())) :: t()
  def update(%__MODULE__{} = state, key, fun) when is_atom(key) and is_function(fun, 1) do
    current = Map.get(state.assigns, key)
    assign(state, key, fun.(current))
  end

  @doc """
  Schedules an async operation for `key`.

  Sets the key to `AsyncResult.loading()` immediately and queues the function
  to be spawned by the Session. The Session drains `pending_async` after each
  callback dispatch.
  """
  @spec async_assign(t(), atom(), (-> any())) :: t()
  def async_assign(%__MODULE__{} = state, key, fun) when is_atom(key) and is_function(fun, 0) do
    state
    |> assign(key, ProjectionUI.AsyncResult.loading())
    |> Map.update!(:pending_async, &[{key, fun} | &1])
  end

  @doc "Returns a sorted list of assign keys that have been modified since the last clear."
  @spec changed_fields(t()) :: [atom()]
  def changed_fields(%__MODULE__{} = state) do
    state.changed
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc "Resets the change set to empty. Called by the session after diffing."
  @spec clear_changed(t()) :: t()
  def clear_changed(%__MODULE__{} = state) do
    %{state | changed: MapSet.new()}
  end
end
