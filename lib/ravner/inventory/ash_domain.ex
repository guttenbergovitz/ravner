defmodule Ravner.Inventory.AshDomain do
  @moduledoc """
  The Ash Domain for Inventory entities (Brand, Organization, Project, etc.).
  """
  use Ash.Domain

  authorization do
    authorize :always
  end

  resources do
    resource Ravner.Inventory.Brand
    resource Ravner.Inventory.Organization
    resource Ravner.Inventory.Project
    resource Ravner.Inventory.ProjectRepository
    resource Ravner.Inventory.Person
    resource Ravner.Inventory.ProjectRole
  end
end
