defmodule Ravner.AshErrorHelpers do
  @moduledoc """
  Translates `Ash.Error.Invalid` and related Ash action errors into
  populated `Ecto.Changeset` error entries for context facade callers.
  """

  @doc """
  Copies field-level or base errors from an `Ash.Error` struct onto `fallback_changeset`,
  guaranteeing that the returned `Ecto.Changeset` has `valid?: false`.
  """
  @spec to_ecto_changeset(term(), Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def to_ecto_changeset(%Ash.Error.Invalid{errors: errors}, %Ecto.Changeset{} = changeset)
      when is_list(errors) and errors != [] do
    Enum.reduce(errors, changeset, fn err, acc ->
      field = extract_field(err)
      msg = extract_message(err)
      Ecto.Changeset.add_error(acc, field, msg)
    end)
  end

  def to_ecto_changeset(other_error, %Ecto.Changeset{} = changeset) do
    Ecto.Changeset.add_error(changeset, :base, extract_message(other_error))
  end

  defp extract_field(%{field: field}) when is_atom(field) and not is_nil(field), do: field
  defp extract_field(%{fields: [field | _]}) when is_atom(field) and not is_nil(field), do: field
  defp extract_field(_), do: :base

  defp extract_message(%{message: msg, vars: vars}) when is_binary(msg) and is_list(vars) do
    Enum.reduce(vars, msg, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", to_string(v))
    end)
  end

  defp extract_message(%{message: msg}) when is_binary(msg), do: msg

  defp extract_message(err) do
    if is_exception(err) do
      Exception.message(err)
    else
      "validation failed"
    end
  end
end
