defmodule BannedCallTracer.Fixture.Apply do
  @moduledoc false
  # Intentional banned call via apply/3 for tracer regression testing.
  # credo:disable-for-next-line
  def run, do: apply(File, :read, ["/etc/passwd"])
end
