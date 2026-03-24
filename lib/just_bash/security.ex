defmodule JustBash.Security do
  @moduledoc """
  Convenience helpers for configuring JustBash security policy.

      bash = JustBash.new()                                       # safe defaults
      bash = JustBash.new(security: :strict)                      # tighter limits
      bash = JustBash.new(security: [max_steps: 50_000])          # tune one knob
      bash = JustBash.new(security: JustBash.Security.strict_policy())
  """

  alias JustBash.Security.Policy

  @type profile :: :default | :strict | :relaxed

  @doc "Returns the default security policy."
  @spec default_policy() :: Policy.t()
  def default_policy, do: Policy.new(:default)

  @doc "Returns the strict security policy."
  @spec strict_policy() :: Policy.t()
  def strict_policy, do: Policy.new(:strict)

  @doc "Returns the relaxed security policy."
  @spec relaxed_policy() :: Policy.t()
  def relaxed_policy, do: Policy.new(:relaxed)

  @doc "Builds a policy from a preset atom or keyword overrides."
  @spec policy(profile() | keyword()) :: Policy.t()
  def policy(spec), do: Policy.new(spec)
end
