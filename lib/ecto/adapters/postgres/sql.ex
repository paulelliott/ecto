defmodule Ecto.Adapters.Postgres.SQL do
  @moduledoc false

  # This module handles the generation of SQL code from queries and for create,
  # update and delete. All queries has to be normalized and validated for
  # correctness before given to this module.

  require Ecto.Query
  alias Ecto.Query.Query
  alias Ecto.Query.QueryExpr
  alias Ecto.Query.QueryUtil

  binary_ops =
    [ ==: "=", !=: "!=", <=: "<=", >=: ">=", <:  "<", >:  ">",
      and: "AND", or: "OR",
      +:  "+", -:  "-", *:  "*", /:  "/" ]

  @binary_ops Dict.keys(binary_ops)

  Enum.map(binary_ops, fn { op, str } ->
    defp binop_to_binary(unquote(op)), do: unquote(str)
  end)

  # Generate SQL for a select statement
  def select(Query[] = query) do
    # Generate SQL for every query expression type and combine to one string
    entities = create_names(query.froms)
    select   = select(query.select, entities)
    from     = from(entities)
    where    = where(query.wheres, entities)
    order_by = order_by(query.order_bys, entities)
    limit    = if query.limit, do: limit(query.limit.expr)
    offset   = if query.offset, do: offset(query.offset.expr)

    [select, from, where, order_by, limit, offset]
      |> Enum.filter(fn x -> x != nil end)
      |> Enum.join("\n")
  end

  # Generate SQL for an insert statement
  def insert(entity) do
    module      = elem(entity, 0)
    table       = module.__ecto__(:dataset)
    fields      = module.__ecto__(:field_names)
    primary_key = module.__ecto__(:primary_key)

    [_|values] = tuple_to_list(entity)

    # Remove primary key from insert fields and values
    if primary_key do
      [_|insert_fields] = fields
      [_|values] = values
    else
      insert_fields = fields
    end

    "INSERT INTO #{table} (" <> Enum.join(insert_fields, ", ") <> ")\n" <>
    "VALUES (" <> Enum.map_join(values, ", ", literal(&1)) <> ")" <>
    if primary_key, do: "\nRETURNING #{primary_key}", else: ""
  end

  # Generate SQL for an update statement
  def update(entity) do
    module      = elem(entity, 0)
    table       = module.__ecto__(:dataset)
    fields      = module.__ecto__(:field_names)
    primary_key = module.__ecto__(:primary_key)

    # Remove primary key from fields and values
    [_|fields] = fields
    [_|[primary_key_value|values]] = tuple_to_list(entity)

    zipped = Enum.zip(fields, values)
    zipped_sql = Enum.map_join(zipped, ", ", fn({k, v}) ->
      "#{k} = #{literal(v)}"
    end)

    "UPDATE #{table} SET " <> zipped_sql <> "\n" <>
    "WHERE #{primary_key} = #{literal(primary_key_value)}"
  end

  # Generate SQL for an update all statement
  def update_all(module, binding, values) when is_atom(module) do
    update_all(Query[froms: [module]], binding, values)
  end

  def update_all(Query[] = query, binding, values) do
    module = Enum.first(query.froms)
    entity = create_names(query.froms) |> Enum.first
    name   = elem(entity, 1)
    table  = module.__ecto__(:dataset)

    vars = QueryUtil.merge_binding_vars(binding, [entity])
    zipped_sql = Enum.map_join(values, ", ", fn({field, expr}) ->
      "#{field} = #{expr(expr, vars)}"
    end)

    where = if query.wheres == [], do: "", else: "\n" <> where(query.wheres, [entity])

    "UPDATE #{table} AS #{name}\n" <>
    "SET " <> zipped_sql <>
    where
  end

  # Generate SQL for a delete statement
  def delete(entity) do
    module            = elem(entity, 0)
    table             = module.__ecto__(:dataset)
    primary_key       = module.__ecto__(:primary_key)
    primary_key_value = elem(entity, 1)

    "DELETE FROM #{table} WHERE #{primary_key} = #{literal(primary_key_value)}"
  end

  # Generate SQL for an delete all statement
  def delete_all(module) when is_atom(module) do
    delete_all(Query[froms: [module]])
  end

  def delete_all(Query[] = query) do
    module = Enum.first(query.froms)
    entity = create_names(query.froms) |> Enum.first
    name   = elem(entity, 1)
    table  = module.__ecto__(:dataset)

    where = if query.wheres == [], do: "", else: "\n" <> where(query.wheres, [entity])

    "DELETE FROM #{table} AS #{name}" <> where
  end

  defp select(QueryExpr[expr: expr, binding: binding], entities) do
    { _, clause } = expr
    vars = QueryUtil.merge_binding_vars(binding, entities)
    "SELECT " <> select_clause(clause, vars)
  end

  defp from(entites) do
    binds = Enum.map_join(entites, ", ", fn({ entity, name }) ->
      "#{entity.__ecto__(:dataset)} AS #{name}"
    end)

    "FROM " <> binds
  end

  defp where([], _vars), do: nil

  defp where(wheres, entities) do
    exprs = Enum.map_join(wheres, " AND ", fn(QueryExpr[expr: expr, binding: binding]) ->
      vars = QueryUtil.merge_binding_vars(binding, entities)
      "(" <> expr(expr, vars) <> ")"
    end)

    "WHERE " <> exprs
  end

  defp order_by([], _vars), do: nil

  defp order_by(order_bys, entities) do
    exprs = Enum.map_join(order_bys, ", ", fn(QueryExpr[expr: expr, binding: binding]) ->
      vars = QueryUtil.merge_binding_vars(binding, entities)
      Enum.map_join(expr, ", ", order_by_expr(&1, vars))
    end)

    "ORDER BY " <> exprs
  end

  defp order_by_expr({ dir, var, field }, vars) do
    { _entity, name } = Keyword.fetch!(vars, var)
    str = "#{name}.#{field}"
    case dir do
      nil   -> str
      :asc  -> str <> " ASC"
      :desc -> str <> " DESC"
    end
  end

  defp limit(num), do: "LIMIT " <> integer_to_binary(num)
  defp offset(num), do: "OFFSET " <> integer_to_binary(num)

  defp expr({ expr, _, [] }, vars) do
    expr(expr, vars)
  end

  defp expr({ :., _, [{ var, _, context }, field] }, vars)
      when is_atom(var) and is_atom(context) and is_atom(field) do
    { _entity, name } = Keyword.fetch!(vars, var)
    "#{name}.#{field}"
  end

  defp expr({ :!, _, [expr] }, vars) do
    "NOT (" <> expr(expr, vars) <> ")"
  end

  # Expression builders make sure that we only find undotted vars at the top level
  defp expr({ var, _, context }, vars) when is_atom(var) and is_atom(context) do
    { entity, name } = Keyword.fetch!(vars, var)
    fields = entity.__ecto__(:field_names)
    Enum.map_join(fields, ", ", fn(field) -> "#{name}.#{field}" end)
  end

  defp expr({ op, _, [expr] }, vars) when op in [:+, :-] do
    atom_to_binary(op) <> expr(expr, vars)
  end

  defp expr({ :==, _, [nil, right] }, vars) do
    "#{op_to_binary(right, vars)} IS NULL"
  end

  defp expr({ :==, _, [left, nil] }, vars) do
    "#{op_to_binary(left, vars)} IS NULL"
  end

  defp expr({ :!=, _, [nil, right] }, vars) do
    "#{op_to_binary(right, vars)} IS NOT NULL"
  end

  defp expr({ :!=, _, [left, nil] }, vars) do
    "#{op_to_binary(left, vars)} IS NOT NULL"
  end

  defp expr({ :in, _, [left, Range[first: first, last: last]] }, vars) do
    expr(left, vars) <> " BETWEEN " <> expr(first, vars) <> " AND " <> expr(last, vars)
  end

  defp expr({ :in, _, [left, right] }, vars) do
    expr(left, vars) <> " = ANY (" <> expr(right, vars) <> ")"
  end

  defp expr(Range[] = range, vars) do
    expr(Enum.to_list(range), vars)
  end

  defp expr({ op, _, [left, right] }, vars) when op in @binary_ops do
    "#{op_to_binary(left, vars)} #{binop_to_binary(op)} #{op_to_binary(right, vars)}"
  end

  defp expr(list, vars) when is_list(list) do
    "ARRAY[" <> Enum.map_join(list, ", ", expr(&1, vars)) <> "]"
  end

  defp expr(literal, _vars), do: literal(literal)

  defp literal(nil), do: "NULL"

  defp literal(true), do: "TRUE"

  defp literal(false), do: "FALSE"

  defp literal(literal) when is_binary(literal) do
    "'#{escape_string(literal)}'"
  end

  defp literal(literal) when is_number(literal) do
    to_binary(literal)
  end

  # TODO: Make sure that Elixir's to_binary for numbers is compatible with PG
  # http://www.postgresql.org/docs/9.2/interactive/sql-syntax-lexical.html

  defp op_to_binary({ op, _, [_, _] } = expr, vars) when op in @binary_ops do
    "(" <> expr(expr, vars) <> ")"
  end

  defp op_to_binary(expr, vars) do
    expr(expr, vars)
  end

  # TODO: Records (Kernel.access)
  defp select_clause({ :{}, _, elems }, vars) do
    Enum.map_join(elems, ", ", select_clause(&1, vars))
  end

  defp select_clause({ x, y }, vars) do
    select_clause({ :{}, [], [x, y] }, vars)
  end

  defp select_clause(list, vars) when is_list(list) do
    Enum.map_join(list, ", ", select_clause(&1, vars))
  end

  defp select_clause(expr, vars) do
    expr(expr, vars)
  end

  defp escape_string(value) when is_binary(value) do
    value
      |> :binary.replace("\\", "\\\\", [:global])
      |> :binary.replace("'", "''", [:global])
  end

  defp create_names(entities) do
    Enum.reduce(entities, [], fn(entity, names) ->
      table = entity.__ecto__(:dataset) |> String.first
      name = unique_name(names, table, 0)
      [{ entity, name }|names]
    end) |> Enum.reverse
  end

  # Brute force find unique name
  defp unique_name(names, name, counter) do
    cnt_name = name <> integer_to_binary(counter)
    if Enum.any?(names, fn({ _, n }) -> n == cnt_name end) do
      unique_name(names, name, counter+1)
    else
      cnt_name
    end
  end
end
