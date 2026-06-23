const COLS = [["goal_id", "goal"], ["on_my_boards", "boards"], ["i_completed", "got"],
  ["beaten", "beaten"], ["my_pct", "got %"], ["beaten_pct", "beaten %"],
  ["my_fastest_sec", "fastest"], ["my_avg_sec", "my avg"],
  ["field_avg_sec", "field"], ["goal_rating", "rating"]];
const $ = id => document.getElementById(id);
let rows = [], key = "goal_rating", asc = false;

function fmtTime(s) {
  if (s == null) return "–";
  const t = Math.round(s), m = Math.floor(t / 60);
  return m ? `${m}m ${t % 60}s` : `${t}s`;
}

function go() {
  const name = $("u").value.trim();
  if (!name) return;
  $("msg").textContent = "loading…";
  Promise.all([
    fetch("/api/player?username=" + encodeURIComponent(name)).then(r => r.json()),
    fetch("/api/goals?username=" + encodeURIComponent(name)).then(r => r.json()),
  ]).then(([player, goals]) => {
    overview(player, name);
    rows = goals;
    key = "goal_rating";
    asc = false;
    $("goals").hidden = goals.length === 0;
    draw();
  }).catch(e => { $("msg").textContent = "error: " + e; });
}

function overview(p, name) {
  const box = $("overview");
  if (!p) {
    box.hidden = true;
    $("msg").textContent = "no competitive data for “" + name + "”";
    return;
  }
  $("msg").textContent = "";
  const cards = [
    ["games", p.games],
    ["record (w-d-l)", p.wins + "-" + p.draws + "-" + p.losses],
    ["win %", p.win_pct],
    ["current elo", p.current_elo ?? "–"],
    ["peak elo", p.peak_elo],
    ["rank", p.rank ? "#" + p.rank : "unranked"],
    ["avg score", p.avg_score],
  ];
  box.innerHTML = "<h2>" + p.username + "</h2>" + cards.map(
    c => `<div class=card><div class=k>${c[0]}</div><div class=v>${c[1]}</div></div>`).join("");
  box.hidden = false;
}

function draw() {
  rows.sort((a, b) => {
    const x = a[key] ?? -Infinity, y = b[key] ?? -Infinity;
    return (x < y ? -1 : x > y ? 1 : 0) * (asc ? 1 : -1);
  });
  $("head").innerHTML = "<tr>" + COLS.map(
    c => `<th data-k="${c[0]}" class="${c[0] == key ? 's ' + (asc ? 'a' : '') : ''}">${c[1]}</th>`).join("") + "</tr>";
  $("body").innerHTML = rows.map(r => "<tr>" + COLS.map(c => {
    let v = r[c[0]];
    if (c[0].endsWith("_sec")) v = fmtTime(v);
    else if (v == null) v = "–";
    const bg = c[0] == "goal_rating" && r[c[0]] != null
      ? ` style="background:hsl(${r[c[0]] * 1.2},55%,30%)"` : "";
    return `<td${bg}>${v}</td>`;
  }).join("") + "</tr>").join("");
}

$("head").addEventListener("click", e => {
  const k = e.target.dataset.k;
  if (!k) return;
  asc = key == k ? !asc : false;
  key = k;
  draw();
});
$("go").addEventListener("click", go);
$("u").addEventListener("keydown", e => { if (e.key == "Enter") go(); });
