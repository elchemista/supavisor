defmodule SupavisorWeb.AdminForm do
  @moduledoc false

  def integer(errors, params, field, min, max \\ 2_147_483_647, optional \\ false) do
    value = params[field]

    valid? =
      case Integer.parse(to_string(value)) do
        {number, ""} -> number >= min and number <= max
        _ -> optional and value in [nil, ""]
      end

    if valid?, do: errors, else: Map.put(errors, field, ["Enter a number from #{min} to #{max}"])
  end

  def choice(errors, params, field, choices) do
    if params[field] in choices,
      do: errors,
      else: Map.put(errors, field, ["Choose one of the available options"])
  end
end
