defmodule Bandera.Gate do
  @moduledoc "A single feature-flag gate and its evaluation."

  alias Bandera.Actor
  alias Bandera.Group

  defstruct [:type, :for, :enabled]

  @type t :: %__MODULE__{
          type: :boolean | :actor | :group | :percentage_of_time | :percentage_of_actors,
          for: term,
          enabled: boolean
        }

  defmodule InvalidTargetError do
    defexception [:message]
  end

  @spec new(:boolean, boolean) :: t
  def new(:boolean, enabled) when is_boolean(enabled) do
    %__MODULE__{type: :boolean, for: nil, enabled: enabled}
  end

  @spec new(:percentage_of_time | :percentage_of_actors, float) :: t
  def new(type, ratio)
      when type in [:percentage_of_time, :percentage_of_actors] and is_float(ratio) and
             ratio > 0.0 and ratio < 1.0 do
    %__MODULE__{type: type, for: ratio, enabled: true}
  end

  def new(type, _ratio) when type in [:percentage_of_time, :percentage_of_actors] do
    raise InvalidTargetError, "#{type} gates require a ratio in the range 0.0 < r < 1.0"
  end

  @spec new(:actor, term, boolean) :: t
  def new(:actor, actor, enabled) when is_boolean(enabled) do
    %__MODULE__{type: :actor, for: Actor.id(actor), enabled: enabled}
  end

  @spec new(:group, atom | String.t(), boolean) :: t
  def new(:group, group_name, enabled) when is_boolean(enabled) do
    %__MODULE__{type: :group, for: to_string(group_name), enabled: enabled}
  end

  @spec boolean?(t) :: boolean
  def boolean?(%__MODULE__{type: :boolean}), do: true
  def boolean?(%__MODULE__{}), do: false

  @spec actor?(t) :: boolean
  def actor?(%__MODULE__{type: :actor}), do: true
  def actor?(%__MODULE__{}), do: false

  @spec group?(t) :: boolean
  def group?(%__MODULE__{type: :group}), do: true
  def group?(%__MODULE__{}), do: false

  @spec percentage_of_time?(t) :: boolean
  def percentage_of_time?(%__MODULE__{type: :percentage_of_time}), do: true
  def percentage_of_time?(%__MODULE__{}), do: false

  @spec percentage_of_actors?(t) :: boolean
  def percentage_of_actors?(%__MODULE__{type: :percentage_of_actors}), do: true
  def percentage_of_actors?(%__MODULE__{}), do: false

  @spec id(t) :: String.t()
  def id(%__MODULE__{type: :boolean}), do: "boolean"
  def id(%__MODULE__{type: :actor, for: actor_id}), do: "actor/#{actor_id}"
  def id(%__MODULE__{type: :group, for: group}), do: "group/#{group}"
  def id(%__MODULE__{type: :percentage_of_time}), do: "percentage"
  def id(%__MODULE__{type: :percentage_of_actors}), do: "percentage"

  @spec enabled?(t, keyword) :: {:ok, boolean} | :ignore
  def enabled?(gate, options \\ [])

  def enabled?(%__MODULE__{type: :boolean, enabled: enabled}, _options) do
    {:ok, enabled}
  end

  def enabled?(%__MODULE__{type: :actor, for: actor_id, enabled: enabled}, for: actor) do
    case Actor.id(actor) do
      ^actor_id -> {:ok, enabled}
      _ -> :ignore
    end
  end

  def enabled?(%__MODULE__{type: :actor}, _options), do: :ignore

  def enabled?(%__MODULE__{type: :group, for: group, enabled: enabled}, for: item) do
    if Group.in?(item, group), do: {:ok, enabled}, else: :ignore
  end

  def enabled?(%__MODULE__{type: :group}, _options), do: :ignore

  def enabled?(%__MODULE__{type: :percentage_of_time, for: ratio}, _options) do
    {:ok, :rand.uniform(10_000) / 10_000 <= ratio}
  end

  def enabled?(%__MODULE__{type: :percentage_of_actors, for: ratio}, options) do
    actor = Keyword.fetch!(options, :for)
    flag_name = Keyword.fetch!(options, :flag_name)
    {:ok, score(actor, flag_name) <= ratio}
  end

  @doc "Deterministic score in [0.0, 1.0) for an actor + flag pair (first 16 bits of SHA-256)."
  @spec score(term, atom) :: float
  def score(actor, flag_name) do
    blob = Actor.id(actor) <> to_string(flag_name)
    <<score::size(16), _rest::binary>> = :crypto.hash(:sha256, blob)
    score / 65_536
  end
end
