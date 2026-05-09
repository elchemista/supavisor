defmodule SupavisorWeb.CoreComponents do
  @moduledoc false

  use Phoenix.Component

  attr(:type, :string, default: "text")
  attr(:name, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:label, :string, default: nil)
  attr(:errors, :list, default: [])
  attr(:options, :list, default: [])
  attr(:checked, :boolean, default: false)
  attr(:readonly, :boolean, default: false)
  attr(:required, :boolean, default: false)
  attr(:rows, :string, default: nil)
  attr(:rest, :global)

  def input(%{type: "select"} = assigns) do
    ~H"""
    <label class="field">
      <span :if={@label}><%= @label %></span>
      <select name={@name} {@rest}>
        <option :for={{label, value} <- @options} value={value} selected={to_string(@value || "") == to_string(value)}>
          <%= label %>
        </option>
      </select>
      <.error :for={error <- @errors}><%= error %></.error>
    </label>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <label class="field">
      <span :if={@label}><%= @label %></span>
      <textarea name={@name} rows={@rows} {@rest}><%= @value %></textarea>
      <.error :for={error <- @errors}><%= error %></.error>
    </label>
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    ~H"""
    <label class="field field-checkbox">
      <input type="hidden" name={@name} value="false" />
      <input type="checkbox" name={@name} value="true" checked={@checked} {@rest} />
      <span :if={@label}><%= @label %></span>
      <.error :for={error <- @errors}><%= error %></.error>
    </label>
    """
  end

  def input(assigns) do
    ~H"""
    <label class="field">
      <span :if={@label}><%= @label %></span>
      <input
        type={@type}
        name={@name}
        value={@value}
        readonly={@readonly}
        required={@required}
        {@rest}
      />
      <.error :for={error <- @errors}><%= error %></.error>
    </label>
    """
  end

  slot(:inner_block, required: true)

  def error(assigns) do
    ~H"""
    <p class="field-error"><%= render_slot(@inner_block) %></p>
    """
  end

  attr(:kind, :string, default: "info")
  slot(:inner_block, required: true)

  def notice(assigns) do
    ~H"""
    <p class={"notice notice-#{@kind}"}><%= render_slot(@inner_block) %></p>
    """
  end

  attr(:variant, :string, default: "neutral", values: ~w(neutral outline solid success warning))
  attr(:icon, :string, default: nil)
  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={"badge badge-#{@variant}"}>
      <span :if={@icon} class={@icon}></span>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:hint, :string, default: nil)
  attr(:icon, :string, default: nil)

  def stat_card(assigns) do
    ~H"""
    <div class="stat-card">
      <div class="stat-head">
        <span :if={@icon} class={["stat-icon", @icon]}></span>
        <span class="stat-label"><%= @label %></span>
      </div>
      <div class="stat-value"><%= @value %></div>
      <div :if={@hint} class="stat-hint"><%= @hint %></div>
    </div>
    """
  end

  attr(:current, :integer, required: true)
  attr(:steps, :list, required: true)

  def stepper(assigns) do
    ~H"""
    <ol class="stepper">
      <li
        :for={{label, index} <- Enum.with_index(@steps, 1)}
        class={[
          "stepper-step",
          index < @current && "is-done",
          index == @current && "is-active"
        ]}
      >
        <span class="stepper-dot"><%= index %></span>
        <span class="stepper-label"><%= label %></span>
      </li>
    </ol>
    """
  end

  attr(:navigate, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:variant, :string, default: "ghost", values: ~w(ghost danger))
  attr(:rest, :global, include: ~w(phx-click phx-value-external-id data-confirm type))

  def icon_button(%{navigate: navigate} = assigns) when not is_nil(navigate) do
    ~H"""
    <.link navigate={@navigate} class={"icon-button icon-button-#{@variant}"} aria-label={@label} title={@label}>
      <span class={@icon}></span>
    </.link>
    """
  end

  def icon_button(assigns) do
    ~H"""
    <button type="button" class={"icon-button icon-button-#{@variant}"} aria-label={@label} title={@label} {@rest}>
      <span class={@icon}></span>
    </button>
    """
  end

  attr(:icon, :string, default: "hero-inbox")
  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  slot(:action)

  def empty_state(assigns) do
    ~H"""
    <div class="empty-state">
      <span class={["empty-state-icon", @icon]}></span>
      <h3 class="empty-state-title"><%= @title %></h3>
      <p :if={@description} class="empty-state-description"><%= @description %></p>
      <div :if={@action != []} class="empty-state-action">
        <%= render_slot(@action) %>
      </div>
    </div>
    """
  end
end
