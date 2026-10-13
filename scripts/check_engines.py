#!/usr/bin/env python3
"""Run the generated SQL on DuckDB and DataFusion and check the answers.

The Swift tests prove the app prints exactly the SQL recorded in
Fixtures/ra_to_sql.json. This script proves that SQL runs on both target
engines and answers what the algebra means. Together they cover the step the
app cannot check by itself: whether a real database accepts what it printed.

    pip install duckdb datafusion
    python3 scripts/check_engines.py
"""

import json
import pathlib
import sys

import datafusion
import duckdb

FIXTURE = pathlib.Path(__file__).resolve().parent.parent / "Fixtures" / "ra_to_sql.json"


def literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    return str(value)


def setup_statements(database):
    for name, table in database.items():
        columns = ", ".join(f"{col} {kind}" for col, kind in table["columns"])
        yield f"CREATE TABLE {name} ({columns})"
        rows = ", ".join("(" + ", ".join(literal(v) for v in row) + ")" for row in table["rows"])
        yield f"INSERT INTO {name} VALUES {rows}"


def duckdb_runner(database):
    con = duckdb.connect()
    for statement in setup_statements(database):
        con.execute(statement)
    return lambda sql: [list(row) for row in con.execute(sql).fetchall()]


def datafusion_runner(database):
    ctx = datafusion.SessionContext()
    for statement in setup_statements(database):
        ctx.sql(statement).collect()

    def run(sql):
        rows = []
        # By column index, not name: `SELECT *` over a join can repeat a name.
        for batch in ctx.sql(sql).collect():
            columns = [batch.column(i).to_pylist() for i in range(batch.num_columns)]
            rows.extend(list(row) for row in zip(*columns))
        return rows

    return run


def canonical(rows):
    """Order-insensitive, and NULL-safe to sort."""
    return sorted(tuple((v is None, str(v)) for v in row) for row in rows)


def main():
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    engines = {
        "duckdb": duckdb_runner(fixture["database"]),
        "datafusion": datafusion_runner(fixture["database"]),
    }
    failures = 0
    for case in fixture["cases"]:
        expected = canonical(case["answer"])
        for engine, run in engines.items():
            try:
                actual = canonical(run(case["sql"]))
            except Exception as error:  # an engine rejecting the SQL is the finding
                failures += 1
                print(f"FAIL {case['name']} on {engine}: {str(error).splitlines()[0]}")
                continue
            if actual != expected:
                failures += 1
                print(f"FAIL {case['name']} on {engine}: got {actual}, expected {expected}")
            else:
                print(f"ok   {case['name']} on {engine}")
    total = len(fixture["cases"]) * len(engines)
    print(f"{total - failures}/{total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
