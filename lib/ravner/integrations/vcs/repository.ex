defmodule Ravner.Integrations.VCS.Repository do
  @moduledoc """
  Normalized representation of a remote version control repository.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          full_name: String.t(),
          url: String.t(),
          clone_url: String.t() | nil,
          provider: :bitbucket | :github | :gitlab | :other,
          description: String.t() | nil,
          main_language: String.t() | nil,
          default_branch: String.t(),
          is_private: boolean(),
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :name,
    :full_name,
    :url,
    :clone_url,
    :provider,
    :description,
    :main_language,
    default_branch: "main",
    is_private: true,
    updated_at: nil
  ]
end
