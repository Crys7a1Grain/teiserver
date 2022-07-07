defmodule Teiserver.Game.MatchRatingLib do
  alias Teiserver.{Account, Game, Battle}
  alias Teiserver.Data.Types, as: T
  alias Central.Repo
  require Logger
  alias Decimal, as: D

  @rated_match_types ["Team", "Duel", "FFA", "Team FFA"]

  @spec rating_type_list() :: [String.t()]
  def rating_type_list() do
    ["Duel", "FFA", "Team FFA", "Small Team", "Large Team"]
  end

  @spec rating_type_id_lookup() :: map()
  def rating_type_id_lookup() do
    rating_type_list()
      |> Map.new(fn name -> {Game.get_or_add_rating_type(name), name} end)
  end

  @spec rating_type_name_lookup() :: map()
  def rating_type_name_lookup() do
    rating_type_list()
      |> Map.new(fn name -> {name, Game.get_or_add_rating_type(name)} end)
  end

  @spec rate_match(non_neg_integer() | Teiserver.Battle.Match.t()) :: :ok | {:error, :no_match}
  def rate_match(match_id) when is_integer(match_id) do
    Battle.get_match(match_id, preload: [:members])
      |> rate_match()
  end

  def rate_match(nil), do: {:error, :no_match}
  def rate_match(match) do
    cond do
      not Enum.member?(@rated_match_types, match.game_type) ->
        {:error, :invalid_game_type}

      match.processed == false ->
        {:error, :not_processed}

      match.winning_team == nil ->
        {:error, :no_winning_team}

      true ->
        do_rate_match(match)
    end
  end

  @spec get_match_type(map()) :: non_neg_integer()
  defp get_match_type(match) do
    name = case match.game_type do
      "Duel" -> "Duel"
      "FFA" -> "FFA"
      "Team FFA" -> "Team FFA"
      "Team" ->
        cond do
          match.team_size <= 4 -> "Small Team"
          match.team_size > 4 -> "Large Team"
        end
    end

    Game.get_or_add_rating_type(name)
  end

  @spec do_rate_match(Teiserver.Battle.Match.t()) :: :ok
  # Currently don't support more than 2 teams
  defp do_rate_match(%{team_count: 2} = match) do
    rating_type_id = get_match_type(match)

    # # Remove existing ratings for this match
    # query = "DELETE FROM teiserver_game_rating_logs WHERE match_id = #{match.id}"
    # Ecto.Adapters.SQL.query(Repo, query, [])

    winners = match.members
      |> Enum.filter(fn membership -> membership.win end)

    losers = match.members
      |> Enum.reject(fn membership -> membership.win end)

    # We will want to update these so we keep the whole object
    rating_lookup = match.members
      |> Map.new(fn membership ->
        rating = Account.get_rating(membership.user_id, rating_type_id)
        {membership.user_id, rating}
      end)

    # Build ratings into lists of tuples for the OpenSkill module to handle
    winner_ratings = winners
      |> Enum.map(fn membership ->
        rating = rating_lookup[membership.user_id]
        {rating.mu |> D.to_float, rating.sigma |> D.to_float}
      end)

    loser_ratings = losers
      |> Enum.map(fn membership ->
        rating = rating_lookup[membership.user_id]
        {rating.mu |> D.to_float, rating.sigma |> D.to_float}
      end)

    # Run the actual calculation
    [win_result, lose_result] = Openskill.rate([winner_ratings, loser_ratings])

    # Save the results
    Enum.zip(winners, win_result)
      |> Enum.each(fn {%{user_id: user_id}, rating_update} ->
        user_rating = rating_lookup[user_id]
        do_update_rating(user_id, match.id, user_rating, rating_update)
      end)

    Enum.zip(losers, lose_result)
      |> Enum.each(fn {%{user_id: user_id}, rating_update} ->
        user_rating = rating_lookup[user_id]
        do_update_rating(user_id, match.id, user_rating, rating_update)
      end)

    :ok
  end
  defp do_rate_match(_), do: :ok

  @spec do_update_rating(T.userid, T.match_id(), map(), {number(), number()}) :: any
  defp do_update_rating(user_id, match_id, user_rating, rating_update) do
    rating_type_id = user_rating.rating_type_id
    {new_mu, new_sigma} = rating_update
    new_ordinal = Openskill.ordinal(rating_update)

    Account.update_rating(user_rating, %{
      ordinal: new_ordinal,
      mu: new_mu,
      sigma: new_sigma
    })

    rating_log = Game.create_rating_log(%{
      user_id: user_id,
      rating_type_id: rating_type_id,
      match_id: match_id,

      value: %{
        ordinal: new_ordinal,
        mu: new_mu,
        sigma: new_sigma,

        old_ordinal: D.to_float(user_rating.ordinal),
        old_mu: D.to_float(user_rating.mu),
        old_sigma: D.to_float(user_rating.sigma),

        ordinal_change: new_ordinal - D.to_float(user_rating.ordinal),
        mu_change: new_mu - D.to_float(user_rating.mu),
        sigma_change: new_sigma - D.to_float(user_rating.sigma),
      }
    })

    case rating_log do
      {:ok, rating_log} -> rating_log
      {:error, changeset} ->
        Logger.error("Error saving rating log: #{Kernel.inspect changeset}")
        nil
    end
  end

  @spec reset_player_ratings() :: :ok
  def reset_player_ratings do
    # Delete all ratings and rating logs
    Ecto.Adapters.SQL.query(Repo, "DELETE FROM teiserver_game_rating_logs", [])
    Ecto.Adapters.SQL.query(Repo, "DELETE FROM teiserver_account_ratings", [])

    {mu, sigma} = default_rating()
    ordinal = Openskill.ordinal({mu, sigma})

    type_ids = rating_type_id_lookup() |> Map.keys()

    ratings = Account.list_users(
      limit: :infinity,
      select: [:id]
    )
      |> Enum.map(fn %{id: user_id} ->
        type_ids
        |> Enum.map(fn type_id ->
          %{
            user_id: user_id,
            rating_type_id: type_id,
            mu: mu,
            sigma: sigma,
            ordinal: ordinal
          }
        end)
      end)
      |> List.flatten

    ratings
      |> Enum.chunk_every(10_000)
      |> Enum.map(fn values ->
        Ecto.Multi.new()
          |> Ecto.Multi.insert_all(:insert_all, Account.Rating, values)
          |> Central.Repo.transaction()
      end)

    :ok
  end

  @spec get_player_rating(T.userid()) :: map
  def get_player_rating(user_id) do
    stats = Account.get_user_stat_data(user_id)

    rating_type_list()
      |> Map.new(fn name ->
        rating_type_id = Game.get_or_add_rating_type(name)

        rating = stats["rating-#{rating_type_id}"]
        ordinal = stats["ordinal-#{rating_type_id}"]
        {name, {ordinal, rating}}
      end)
  end

  @spec re_rate_all_matches :: non_neg_integer()
  def re_rate_all_matches() do
    match_ids = Battle.list_matches(
      search: [
        game_type_in: @rated_match_types,
        processed: true
      ],
      order_by: "Oldest first",
      limit: :infinity,
      select: [:id]
    )
    |> Enum.map(fn %{id: id} -> id end)

    match_count = Enum.count(match_ids)

    match_ids
      |> Enum.chunk_every(50)
      |> Enum.each(fn ids ->
        re_rate_specific_matches(ids)
      end)

    match_count
  end

  @spec reset_and_re_rate() :: :ok
  def reset_and_re_rate() do
    start_time = System.system_time(:millisecond)

    reset_player_ratings()
    match_count = re_rate_all_matches()

    time_taken = System.system_time(:millisecond) - start_time
    Logger.info("re_rate_all_matches, took #{time_taken}ms for #{match_count} matches")
  end

  defp re_rate_specific_matches(ids) do
    Battle.list_matches(
      search: [
        id_in: ids
      ],
      limit: :infinity,
      preload: [:members]
    )
    |> Enum.map(fn match -> rate_match(match) end)
  end

  @spec default_rating :: List.t()
  def default_rating() do
    Openskill.rating()
  end
end