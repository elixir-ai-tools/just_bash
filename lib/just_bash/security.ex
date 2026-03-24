defmodule JustBash.Security do
  @moduledoc """
  Public helpers for configuring JustBash security policy.

  This is the preferred host-facing API for selecting execution profiles and
  constructing custom policies. The default policy is intended to be safe for
  untrusted code and enables resource limits by default. For example:

      bash = JustBash.new()
      bash = JustBash.new(security: JustBash.Security.strict_policy())
      bash = JustBash.new(security: [profile: :strict, max_steps: 10_000])

  Top-level `max_*` options are no longer accepted — pass them under the
  `:security` key instead (see the Upgrading section in the README).
  """

  alias JustBash.Security.Policy

  @type profile :: :default | :strict | :relaxed

  @doc "Returns the default security policy."
  @spec default_policy() :: Policy.t()
  def default_policy, do: policy(:default)

  @doc "Returns the stricter untrusted-code execution policy."
  @spec strict_policy() :: Policy.t()
  def strict_policy, do: policy(:strict)

  @doc "Returns the relaxed execution policy."
  @spec relaxed_policy() :: Policy.t()
  def relaxed_policy, do: policy(:relaxed)

  @doc "Builds a policy from a preset atom or keyword overrides."
  @spec policy(profile() | keyword()) :: Policy.t()
  def policy(profile) when profile in [:default, :strict, :relaxed] do
    profile
    |> Policy.preset()
    |> then(&struct(Policy, &1))
  end

  def policy(opts) when is_list(opts), do: Policy.new(opts)
end
