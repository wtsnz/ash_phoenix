# SPDX-FileCopyrightText: 2020 ash_phoenix contributors <https://github.com/ash-project/ash_phoenix/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPhoenix.Plug.CheckCodegenStatusTest do
  # persistent_term and the build lock are global state
  use ExUnit.Case, async: false

  alias AshPhoenix.Plug.CheckCodegenStatus

  defmodule CleanExtension do
    def codegen(_args) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid}, nil)

      # When a test is driving us, block until it says to continue. This pins
      # the check open for as long as the test needs, instead of guessing a
      # sleep duration.
      if test_pid do
        send(test_pid, {:codegen_started, self()})

        receive do
          :proceed -> :ok
        end
      end

      :ok
    end
  end

  defmodule RacyExtension do
    # Reports a diff on the first check, like a check that raced the code
    # reloader, and is clean when checked again.
    def codegen(args) do
      if Process.get({__MODULE__, :checked}) do
        CleanExtension.codegen(args)
      else
        Process.put({__MODULE__, :checked}, true)

        raise Ash.Error.Framework.PendingCodegen,
          diff: %{"priv/repo/migrations/1_example.exs" => "contents"}
      end
    end
  end

  defmodule PendingExtension do
    def codegen(_args) do
      raise Ash.Error.Framework.PendingCodegen,
        diff: %{"priv/repo/migrations/1_example.exs" => "contents"}
    end
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase(:ash_codegen_extensions)
      :persistent_term.erase({CleanExtension, :test_pid})
    end)

    :ok
  end

  test "passes the conn through when no codegen is pending" do
    :persistent_term.put(:ash_codegen_extensions, [CleanExtension])

    conn = Plug.Test.conn(:get, "/")
    assert %Plug.Conn{} = CheckCodegenStatus.call(conn, [])
  end

  test "raises PendingCodegen when an extension reports a diff" do
    :persistent_term.put(:ash_codegen_extensions, [PendingExtension])

    conn = Plug.Test.conn(:get, "/")

    assert_raise Plug.Conn.WrapperError, ~r/Pending/i, fn ->
      CheckCodegenStatus.call(conn, [])
    end
  end

  if Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :with_build_lock, 1) do
    test "does not take the build lock when no codegen is pending" do
      # Taking the build lock on every request makes concurrent requests wait
      # on each other and on the code reloader.
      :persistent_term.put(:ash_codegen_extensions, [CleanExtension])

      Mix.Project.with_build_lock(fn ->
        plug_task =
          Task.async(fn ->
            CheckCodegenStatus.call(Plug.Test.conn(:get, "/"), [])
          end)

        assert {:ok, %Plug.Conn{}} = Task.yield(plug_task, 1_000),
               "expected the codegen check not to wait for the build lock"
      end)
    end

    test "confirms a reported diff while holding the build lock" do
      # The check reads global compiler data: the Mix project stack and the
      # current directory. Phoenix.CodeReloader changes this data when it
      # compiles umbrella apps (Mix.Dep.in_dependency calls File.cd!).
      # If a reload occurs at the same time, the check reads incorrect paths
      # and reports pending codegen that is not real. Checking again while
      # holding the build lock discards that report.
      :persistent_term.put(:ash_codegen_extensions, [RacyExtension])
      :persistent_term.put({CleanExtension, :test_pid}, self())

      plug_task =
        Task.async(fn ->
          CheckCodegenStatus.call(Plug.Test.conn(:get, "/"), [])
        end)

      assert_receive {:codegen_started, codegen_pid}, 1_000

      lock_task = Task.async(fn -> Mix.Project.with_build_lock(fn -> :acquired end) end)

      # The check cannot have finished yet: codegen is blocked until we send
      # :proceed below. So a lock that is still unavailable here means the
      # check is holding it, not that the check already returned.
      assert Task.yield(lock_task, 100) == nil,
             "expected the codegen check to hold the build lock while confirming a diff"

      send(codegen_pid, :proceed)

      # The diff was not confirmed, so the request goes through
      assert %Plug.Conn{} = Task.await(plug_task, 2_000)
      assert {:ok, :acquired} = Task.yield(lock_task, 1_000)
    end
  end
end
