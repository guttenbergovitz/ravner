defmodule RavnerWeb.Router do
  use RavnerWeb, :router

  import RavnerWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {RavnerWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(RavnerWeb.Plugs.RequireSetup)
    plug(:fetch_current_scope_for_user)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :require_admin do
    plug(RavnerWeb.Plugs.RequireRole, :admin)
  end

  pipeline :require_editor do
    plug(RavnerWeb.Plugs.RequireRole, :editor)
  end

  scope "/", RavnerWeb do
    pipe_through(:browser)

    get("/setup", SetupController, :new)
    post("/setup", SetupController, :create)
  end

  # Other scopes may use custom stacks.
  # scope "/api", RavnerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ravner, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: RavnerWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  ## Authentication routes

  scope "/", RavnerWeb do
    pipe_through([:browser, :redirect_if_user_is_authenticated])

    get("/users/register", UserRegistrationController, :new)
    post("/users/register", UserRegistrationController, :create)
  end

  scope "/", RavnerWeb do
    pipe_through([:browser, :require_authenticated_user])

    get("/users/settings", UserSettingsController, :edit)
    put("/users/settings", UserSettingsController, :update)
    get("/users/settings/confirm-email/:token", UserSettingsController, :confirm_email)
  end

  scope "/", RavnerWeb do
    pipe_through([:browser, :require_authenticated_user])

    get("/domains/export", DomainExportController, :index)

    live_session :authenticated, on_mount: [{RavnerWeb.UserAuth, :ensure_authenticated}] do
      live("/", DashboardLive.Index, :index)
      live("/domains", DomainLive.Index, :index)
      live("/domains/new", DomainLive.Index, :new)
      live("/domains/import", DomainLive.Index, :import)
      live("/domains/:id", DomainLive.Show, :show)
      live("/domains/:id/edit", DomainLive.Show, :edit)
    end
  end

  # Admin-only routes — require :admin role via plug and on_mount
  scope "/admin", RavnerWeb do
    pipe_through([:browser, :require_authenticated_user, :require_admin])

    live_session :admin, on_mount: [{RavnerWeb.UserAuth, :ensure_admin}] do
      live("/users", AdminLive.Users, :index)
      live("/users/new", AdminLive.Users, :new)
      live("/users/:id/edit", AdminLive.Users, :edit)
      live("/invites", AdminLive.Invites, :index)
      live("/invites/new", AdminLive.Invites, :new)
      live("/settings", AdminLive.Settings, :index)
    end
  end

  # Invite accept route — accessible without full auth (user sets password here)
  scope "/", RavnerWeb do
    pipe_through([:browser])

    get("/users/invite/:token", UserInviteController, :show)
    post("/users/invite/:token", UserInviteController, :create)
  end

  scope "/", RavnerWeb do
    pipe_through([:browser])

    get("/users/log-in", UserSessionController, :new)
    get("/users/log-in/:token", UserSessionController, :confirm)
    post("/users/log-in", UserSessionController, :create)
    delete("/users/log-out", UserSessionController, :delete)
  end
end
