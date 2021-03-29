defmodule TeiserverWeb.ClientLive.Show do
  use TeiserverWeb, :live_view
  alias Phoenix.PubSub
  require Logger

  alias Teiserver.User
  alias Teiserver.Client
  import Central.Helpers.NumberHelper, only: [int_parse: 1]

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> AuthPlug.live_call(session)
      |> NotificationPlug.live_call()
      |> add_breadcrumb(name: "Teiserver", url: "/teiserver")
      |> add_breadcrumb(name: "Admin", url: "/teiserver/admin")
      |> add_breadcrumb(name: "Clients", url: "/teiserver/admin/clients")
      |> assign(:sidemenu_active, "teiserver")
      |> assign(:colours, Central.Helpers.StylingHelper.colours(:primary2))

    {:ok, socket, layout: {CentralWeb.LayoutView, "blank_live.html"}}
  end

  @impl true
  def handle_params(%{"id" => id}, _opts, socket) do
    id = int_parse(id)
    PubSub.subscribe(Central.PubSub, "all_user_updates")
    PubSub.subscribe(Central.PubSub, "all_client_updates")
    PubSub.subscribe(Central.PubSub, "user_updates:#{id}")
    client = Client.get_client_by_id(id)
    user = User.get_user_by_id(id)

    case client do
      nil ->
        {:noreply,
        socket
        |> redirect(to: Routes.ts_admin_client_index_path(socket, :index))}
      _ ->
        {:noreply,
          socket
          |> assign(:page_title, page_title(socket.assigns.live_action))
          |> add_breadcrumb(name: client.name, url: "/teiserver/admin/clients/#{id}")
          |> assign(:id, id)
          |> assign(:client, client)
          |> assign(:user, user)}
    end
  end

  @impl true
  def handle_info({:updated_client, new_client, _reason}, socket) do
    {:noreply, assign(socket, :client, new_client)}
  end

  def handle_info({:user_logged_out, client_id, _name}, socket) do
    if int_parse(client_id) == socket.assigns[:id] do
      {:noreply,
       socket
       |> redirect(to: Routes.ts_admin_client_index_path(socket, :index))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("force-disconnect", _event, socket) do
    Client.disconnect(socket.assigns[:id])
    {:noreply, socket}
  end

  def handle_event("action:extra_logging", _event, socket) do
    send(socket.assigns[:client].pid, {:put, :extra_logging, true})
    {:noreply, socket}
  end

  def handle_event("action:less_logging", _event, socket) do
    send(socket.assigns[:client].pid, {:put, :extra_logging, false})
    {:noreply, socket}
  end

  defp page_title(:show), do: "Show Client"
end
