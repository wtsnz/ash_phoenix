# SPDX-FileCopyrightText: 2020 ash_phoenix contributors <https://github.com/ash-project/ash_phoenix/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPhoenix.FilterFormPoliciesTest do
  @moduledoc """
  A FilterForm's filter comes from submitted params, so it applies field policies and the read
  policies of related resources, as `Ash.Query.filter_input/3` does.
  """
  use ExUnit.Case, async: true

  alias AshPhoenix.FilterForm

  require Ash.Query

  defmodule Comment do
    @moduledoc false
    use Ash.Resource,
      domain: AshPhoenix.FilterFormPoliciesTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private? true
    end

    policies do
      policy action_type(:read) do
        authorize_if expr(visible == true)
      end

      policy action_type(:create) do
        authorize_if always()
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :body, :string, public?: true
      attribute :visible, :boolean, public?: true, default: true
    end

    relationships do
      belongs_to :post, AshPhoenix.FilterFormPoliciesTest.Post,
        public?: true,
        attribute_writable?: true
    end

    actions do
      defaults [:read, create: :*]
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource,
      domain: AshPhoenix.FilterFormPoliciesTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private? true
    end

    policies do
      policy always() do
        authorize_if always()
      end
    end

    field_policies do
      field_policy :internal_score do
        authorize_if actor_attribute_equals(:admin?, true)
      end

      field_policy :* do
        authorize_if always()
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :internal_score, :integer, public?: true
    end

    relationships do
      has_many :comments, AshPhoenix.FilterFormPoliciesTest.Comment, public?: true
    end

    actions do
      defaults [:read, create: :*]
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshPhoenix.FilterFormPoliciesTest.Post
      resource AshPhoenix.FilterFormPoliciesTest.Comment
    end
  end

  @user [actor: %{admin?: false}, authorize?: true]
  @admin [actor: %{admin?: true}, authorize?: true]

  setup do
    post = Ash.create!(Post, %{title: "Hello", internal_score: 42}, authorize?: false)
    Ash.create!(Comment, %{body: "public", post_id: post.id}, authorize?: false)
    Ash.create!(Comment, %{body: "secret", visible: false, post_id: post.id}, authorize?: false)
    :ok
  end

  defp count(params, opts) do
    form = Post |> FilterForm.new() |> FilterForm.validate(params)

    {:ok, query} = FilterForm.filter(Post, form)
    via_filter = query |> Ash.read!(opts) |> length()
    via_filter! = Post |> FilterForm.filter!(form) |> Ash.read!(opts) |> length()

    assert via_filter == via_filter!
    via_filter
  end

  defp predicate(field, operator, value, path \\ nil) do
    predicate = %{"field" => field, "operator" => operator, "value" => value}
    predicate = if path, do: Map.put(predicate, "path", path), else: predicate
    %{"operator" => "and", "components" => %{"0" => predicate}}
  end

  test "a field the user can't see doesn't match" do
    assert count(predicate("internal_score", "eq", 42), @user) == 0
    assert count(predicate("internal_score", "greater_than", 40), @user) == 0
  end

  test "a related record the user can't read doesn't match" do
    assert count(predicate("body", "eq", "secret", "comments"), @user) == 0
  end

  test "fields and related records the user can see still match" do
    assert count(predicate("title", "eq", "Hello"), @user) == 1
    assert count(predicate("body", "eq", "public", "comments"), @user) == 1
  end

  test "an exported expression is client input however it's applied" do
    form = Post |> FilterForm.new() |> FilterForm.validate(predicate("internal_score", "eq", 42))
    filter = FilterForm.to_filter_expression!(form)

    related_form =
      Post
      |> FilterForm.new()
      |> FilterForm.validate(predicate("body", "eq", "secret", "comments"))

    related = FilterForm.to_filter_expression!(related_form)

    # The previously documented usage, with a trusted filter.
    assert Post |> Ash.Query.filter(^filter) |> Ash.read!(@user) |> length() == 0
    assert Post |> Ash.Query.filter(^related) |> Ash.read!(@user) |> length() == 0
    assert Post |> Ash.Query.filter_input(filter) |> Ash.read!(@user) |> length() == 0
    assert Post |> Ash.Query.filter(^filter) |> Ash.read!(@admin) |> length() == 1

    deprecated = apply(FilterForm, :to_filter!, [form])
    assert Post |> Ash.Query.filter(^deprecated) |> Ash.read!(@user) |> length() == 0
  end

  test "an admin can filter on the field" do
    assert count(predicate("internal_score", "eq", 42), @admin) == 1
    assert count(predicate("internal_score", "eq", 41), @admin) == 0
  end
end
