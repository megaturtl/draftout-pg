#!/usr/bin/env python3
"""Minimal stats explorer. Run in `nix develop`:  python app.py

Serves the static frontend in web/ and answers /api/* from the local `psql`
CLI (JSON straight out of the views/functions in views.sql)."""
import os
import re
import subprocess
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8000"))
WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
NAME_RE = re.compile(r"[A-Za-z0-9_]{1,16}")  # validates usernames, blocks injection
os.environ.setdefault("PGHOST", "localhost")  # psql talks TCP to the local server

GOALS = "SELECT coalesce(json_agg(t ORDER BY t.goal_rating DESC), '[]'::json) " \
        "FROM player_goal_stats((SELECT uuid FROM players WHERE lower(current_name)=lower(:'username'))) t;"
OVERVIEW = """
           SELECT row_to_json(o)
           FROM (SELECT s.username,
                        s.games,
                        s.wins,
                        s.draws,
                        s.losses,
                        s.win_pct,
                        s.avg_score,
                        s.peak_elo,
                        (SELECT elo_after
                         FROM v_results
                         WHERE uuid = s.uuid
                           AND elo_after IS NOT NULL
                         ORDER BY match_id DESC
                         LIMIT 1)                                            current_elo,
                        (SELECT rank FROM v_leaderboard WHERE uuid = s.uuid) rank
                 FROM v_player_stats s
                 WHERE s.uuid = (SELECT uuid FROM players WHERE lower(current_name) = lower(:'username'))) o;"""
ROUTES = {"/api/goals": (GOALS, "[]"), "/api/player": (OVERVIEW, "null")}


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path not in ROUTES:
            return super().do_GET()  # static files: handled natively from web/
        sql, empty = ROUTES[url.path]
        name = (parse_qs(url.query).get("username") or [""])[0]
        out = subprocess.run(["psql", "-tAXq", "-v", "username=" + name], input=sql,
                             stdout=subprocess.PIPE, text=True).stdout.strip() if NAME_RE.fullmatch(name) else ""
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write((out or empty).encode())


if __name__ == "__main__":
    print(f">> draftout explorer on http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), partial(Handler, directory=WEB)).serve_forever()
