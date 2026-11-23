defmodule Ravner.Integrations.VCS.Commit do
  @moduledoc """
  Normalized representation of a version control commit.
  """

  @type t :: %__MODULE__{
          hash: String.t(),
          short_hash: String.t(),
          message: String.t(),
          author_name: String.t() | nil,
          author_email: String.t() | nil,
          committed_at: DateTime.t() | nil,
          url: String.t() | nil
        }

  defstruct [
    :hash,
    :short_hash,
    :message,
    :author_name,
    :author_email,
    :committed_at,
    :url
  ]
end
