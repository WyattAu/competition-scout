#!/usr/bin/env bash
# Competition scout: fetches venue sources, stores everything in SQLite,
# reports NEW venues on stdout. Designed to run unattended (automation).
set -uo pipefail
DB="$HOME/dev/src/arjaythedev/scout/competitions.db"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS venues (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,
  name TEXT NOT NULL,
  url TEXT DEFAULT '',
  category TEXT DEFAULT '',
  status TEXT DEFAULT 'open',
  first_seen TEXT, last_seen TEXT,
  notes TEXT DEFAULT '',
  UNIQUE(source, name)
);
CREATE TABLE IF NOT EXISTS scout_runs (
  id INTEGER PRIMARY KEY, ran_at TEXT, new_count INTEGER, errors TEXT DEFAULT ''
);"

report_new() { echo "NEW: [$1] $2 ($3)"; }
declare -a NEW

fetch() { curl -sfL --max-time 20 -H 'User-Agent: estate-scout' "$1"; }

upsert() { # source name url category status
  local src="$1" name="$2" url="$3" cat="$4" status="$5"
  local exists=$(sqlite3 "$DB" "SELECT COUNT(*) FROM venues WHERE source='$src' AND name='$name';")
  if [ "$exists" = "0" ]; then
    sqlite3 "$DB" "INSERT INTO venues (source,name,url,category,status,first_seen,last_seen) VALUES ('$src','$name','$url','$cat','$status','$NOW','$NOW');"
    NEW+=("$src|$name|$url|$cat")
  else
    sqlite3 "$DB" "UPDATE venues SET last_seen='$NOW', status='$status' WHERE source='$src' AND name='$name';"
  fi
}

# source 1: arjaythedev repos (new challenges surface here first)
if J=$(fetch "https://api.github.com/users/arjaythedev/repos?sort=created&per_page=30"); then
  while IFS='|' read -r name desc url; do
    [ -z "$name" ] && continue
    upsert "arjaythedev" "$name" "$url" "api-challenge" "open"
  done < <(echo "$J" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    print(r['name']+'|'+(r.get('description') or '')[:100]+'|'+r['html_url'])
")
fi

# source 2: 1brc org tracks
if J=$(fetch "https://api.github.com/orgs/1brc/repos?per_page=100"); then
  while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    upsert "1brc" "$name" "$url" "1brc-track" "open"
  done < <(echo "$J" | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    print(r['name']+'|'+r['html_url'])
")
fi

# source 3: 1brc.dev site (language tracks + closed markers)
if P=$(fetch "https://1brc.dev/"); then
  while IFS= read -r lang; do
    [ -z "$lang" ] && continue
    upsert "1brc-dev" "track-$lang" "https://1brc.dev/#$lang" "1brc-track" "open"
  done < <(echo "$P" | grep -oE '1BRC in [A-Za-z+#]+' | sed 's/1BRC in //' | sort -u)
fi

# source 4: Speed Demon (next edition watch)
if P=$(fetch "https://speeddemon.dev/"); then
  upsert "speeddemon" "speed-demon" "https://speeddemon.dev/" "perf-championship" "watch"
fi

# source 5: Kaggle optimization listing (count only changes tracked via venues table)
if P=$(fetch "https://www.kaggle.com/competitions?tagIds=15002-Optimization"); then
  while IFS= read -r comp; do
    [ -z "$comp" ] && continue
    upsert "kaggle" "$comp" "https://www.kaggle.com/competitions" "optimization" "live"
  done < <(echo "$P" | grep -oE 'Santa [0-9]{4}[^<"|]*' | sort -u | head -5)
fi

# static curated venues: keep last_seen fresh
upsert "curated" "twelve-dollar-server-challenge" "https://benchmarks.arjaythedev.com/12-dollar-server" "api-challenge" "queued"
upsert "curated" "sat-competition-2027" "https://satcompetition.github.io/" "solver" "planned"
upsert "curated" "maxsat-evaluation-2027" "https://maxsat-evaluations.github.io/" "solver" "planned"
upsert "curated" "iccma-2027" "https://argumentationcompetition.org/2027/rules.html" "solver" "planned"
upsert "curated" "gpu-mode-kernel-leaderboards" "https://gpumode.com/" "gpu-kernel" "open"
upsert "curated" "advent-of-code-2026" "https://adventofcode.com/2026" "algorithmic" "starts-Dec-1"
upsert "curated" "santa-2026-elf-calculator" "https://www.kaggle.com/competitions/santa-2026/" "optimization" "live"

sqlite3 "$DB" "INSERT INTO scout_runs (ran_at, new_count) VALUES ('$NOW', ${#NEW[@]});"
echo "scout run complete: ${#NEW[@]} new venues, total $(sqlite3 "$DB" 'SELECT COUNT(*) FROM venues;')"
for n in "${NEW[@]}"; do report_new $(echo "$n" | tr '|' ' '); done
