#!/usr/bin/env bash
set -euo pipefail

db="${1:-${STARLIGHT_DB:-$(dirname "$0")/../master.db}}"

ls -la "$db"*
echo

sqlite3 -readonly -header -column "$db" "
SELECT name,
       COUNT(*) AS pages,
       SUM(pgsize) / 1024 AS kb,
       ROUND(100.0 * SUM(pgsize) / (SELECT SUM(pgsize) FROM dbstat), 1) AS pct
FROM dbstat
GROUP BY name
ORDER BY kb DESC;"
echo

sqlite3 -readonly -header -column "$db" "
SELECT (SELECT page_count FROM pragma_page_count) * (SELECT page_size FROM pragma_page_size) / 1024 AS total_kb,
       (SELECT freelist_count FROM pragma_freelist_count) * (SELECT page_size FROM pragma_page_size) / 1024 AS free_kb;"
