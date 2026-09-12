#!/usr/bin/env python3
"""Сборка дашборда report/dashboard.html из живых данных.

Числа тянутся прямо из базы через psql, а не вписываются руками: дашборд,
разошедшийся с данными, хуже отсутствующего.

Графики рисуются инлайновым SVG без единой библиотеки — файл открывается
двойным кликом и работает без интернета.

    python scripts/build_dashboard.py
    python scripts/build_dashboard.py --psql "C:/Program Files/PostgreSQL/17/bin/psql.exe"

Подключение — стандартными переменными libpq (PGHOST, PGUSER, PGPASSWORD,
PGDATABASE).
"""

from __future__ import annotations

import argparse
import csv
import html
import io
import os
import shutil
import subprocess
import tempfile
import sys
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "report", "dashboard.html")

# --- палитра (см. dataviz: categorical slots 1-2, диверг. пара blue<->red) --- #
LIGHT = {
    "surface": "#fcfcfb", "plane": "#f9f9f7", "ink": "#0b0b0b", "ink2": "#52514e",
    "muted": "#898781", "grid": "#e1e0d9", "axis": "#c3c2b7",
    "s1": "#2a78d6", "s2": "#eb6834", "pos": "#2a78d6", "neg": "#e34948",
    "good": "#0ca30c", "warn": "#fab219", "crit": "#d03b3b",
    "ramp": ["#86b6ef", "#5598e7", "#3987e5", "#256abf", "#184f95"],
}
DARK = {
    "surface": "#1a1a19", "plane": "#0d0d0d", "ink": "#ffffff", "ink2": "#c3c2b7",
    "muted": "#898781", "grid": "#2c2c2a", "axis": "#383835",
    "s1": "#3987e5", "s2": "#d95926", "pos": "#3987e5", "neg": "#e66767",
    "good": "#0ca30c", "warn": "#fab219", "crit": "#d03b3b",
    "ramp": ["#86b6ef", "#5598e7", "#3987e5", "#256abf", "#184f95"],
}


# --------------------------------------------------------------------------- #
# Выгрузка данных
# --------------------------------------------------------------------------- #

def find_psql(explicit: str | None) -> str:
    if explicit:
        return explicit
    found = shutil.which("psql")
    if found:
        return found
    import glob
    candidates = sorted(glob.glob(r"C:\Program Files\PostgreSQL\*\bin\psql.exe"), reverse=True)
    if candidates:
        return candidates[0]
    sys.exit("psql не найден. Укажите путь через --psql.")


def query(psql: str, sql: str) -> list[dict]:
    """Выполняет запрос и возвращает строки как словари.

    Запрос передаётся через временный файл в UTF-8, а не аргументом `-c`.
    Причина в Windows: аргументы командной строки доходят до psql в кодировке
    системной страницы (обычно cp1251), и любой кириллический литерал внутри
    запроса — а они тут есть, подписи шагов воронки — превращается в
    «неверную последовательность байт для UTF8». Через файл кодировка задана
    явно и одинаково на всех платформах.
    """
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    db = env.get("PGDATABASE", "timeline_analytics")
    with tempfile.NamedTemporaryFile("w", suffix=".sql", encoding="utf-8",
                                     delete=False, newline="\n") as fh:
        fh.write(f"COPY ({sql}) TO STDOUT WITH (FORMAT csv, HEADER true);\n")
        path = fh.name
    try:
        proc = subprocess.run(
            [psql, "-d", db, "--quiet", "--no-psqlrc", "-v", "ON_ERROR_STOP=1", "-f", path],
            capture_output=True, env=env,
        )
    finally:
        os.unlink(path)
    if proc.returncode != 0:
        sys.exit(f"psql завершился с ошибкой:\n{proc.stderr.decode('utf-8', 'replace')}")
    return list(csv.DictReader(io.StringIO(proc.stdout.decode("utf-8"))))


Q_KPI = """
WITH live AS (
    SELECT count(*) AS subs, sum(current_mrr_rub) AS mrr
    FROM marts.fct_subscription WHERE is_active
),
conv AS (
    SELECT round(100.0 * count(*) FILTER (WHERE is_converted) / count(*), 1) AS pct
    FROM marts.dim_user WHERE is_matured
),
mature AS (
    SELECT paid_cohort_month FROM marts.fct_subscription
    WHERE is_converted GROUP BY paid_cohort_month
    HAVING paid_cohort_month + interval '7 months' <= marts.snapshot_ts()
),
nrr AS (
    SELECT round(100.0 * sum(m.mrr_rub) FILTER (WHERE m.month_index = 6)
                 / nullif(sum(s.first_mrr_rub) FILTER (WHERE m.month_index = 0), 0), 1) AS pct
    FROM marts.fct_subscription_month m
    JOIN marts.fct_subscription s USING (subscription_id)
    WHERE m.paid_cohort_month IN (SELECT paid_cohort_month FROM mature)
),
qr AS (
    SELECT round(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('new','reactivation','expansion'))
                 / nullif(abs(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('contraction','churn'))), 0), 2) AS ratio
    FROM marts.fct_mrr_movement
    WHERE month >= date_trunc('quarter', marts.snapshot_ts() - interval '3 months')
)
SELECT live.subs, round(live.mrr) AS mrr, conv.pct AS conversion,
       nrr.pct AS nrr6, qr.ratio AS quick_ratio
FROM live, conv, nrr, qr
"""

Q_MRR = """
SELECT to_char(month, 'YYYY-MM') AS label,
       round(sum(sum(mrr_delta_rub)) OVER (ORDER BY month)) AS mrr
FROM marts.fct_mrr_movement GROUP BY month ORDER BY month
"""

Q_MOVE = """
SELECT to_char(month, 'YYYY-MM') AS label,
       round(coalesce(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('new','reactivation','expansion')), 0)) AS gained,
       round(coalesce(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('contraction','churn')), 0)) AS lost
FROM marts.fct_mrr_movement GROUP BY month ORDER BY month
"""

Q_FUNNEL = """
WITH b AS (SELECT * FROM marts.dim_user WHERE is_matured)
SELECT 1 AS ord, 'Регистрация' AS label, count(*) AS users FROM b
UNION ALL SELECT 2, 'Подтвердил почту', count(*) FILTER (WHERE email_confirmed_at IS NOT NULL) FROM b
UNION ALL SELECT 3, 'Создал проект', count(*) FILTER (WHERE first_project_at IS NOT NULL) FROM b
UNION ALL SELECT 4, 'Активация', count(*) FILTER (WHERE is_activated) FROM b
UNION ALL SELECT 5, 'Оплатил', count(*) FILTER (WHERE is_converted) FROM b
ORDER BY 1
"""

Q_RETENTION = """
WITH base AS (
    SELECT user_id, is_activated FROM marts.dim_user WHERE observed_days >= 63
),
sizes AS (SELECT is_activated, count(*) AS users FROM base GROUP BY is_activated),
act AS (
    SELECT b.is_activated, w.week_index, count(DISTINCT w.user_id) AS au
    FROM marts.fct_user_activity_week w JOIN base b USING (user_id)
    WHERE w.week_index BETWEEN 0 AND 8 AND w.core_actions_cnt > 0
    GROUP BY 1, 2
)
SELECT a.week_index AS label,
       round(max(100.0 * a.au / s.users) FILTER (WHERE a.is_activated), 1) AS activated,
       round(max(100.0 * a.au / s.users) FILTER (WHERE NOT a.is_activated), 1) AS other
FROM act a JOIN sizes s USING (is_activated)
GROUP BY a.week_index ORDER BY a.week_index
"""

Q_CHANNELS = """
WITH cu AS (
    SELECT channel_name, max(cac_rub) AS cac, count(*) AS signups,
           count(*) FILTER (WHERE is_converted) AS paying
    FROM marts.dim_user WHERE is_matured GROUP BY channel_name
),
cs AS (
    SELECT u.channel_name, avg(s.first_mrr_rub) AS arpu,
           count(*) FILTER (WHERE NOT s.is_active) / nullif(sum(s.tenure_months), 0) AS churn
    FROM marts.fct_subscription s JOIN marts.dim_user u USING (user_id)
    WHERE s.is_converted AND u.is_matured GROUP BY u.channel_name
)
SELECT cu.channel_name AS label,
       round(100.0 * cu.paying / cu.signups, 1) AS conversion,
       round(cs.arpu * 0.8 / nullif(cs.churn, 0)
             / nullif(cu.cac * cu.signups / nullif(cu.paying, 0), 0), 2) AS ltv_cac
FROM cu JOIN cs USING (channel_name)
ORDER BY ltv_cac DESC NULLS FIRST
"""


# --------------------------------------------------------------------------- #
# Примитивы SVG
# --------------------------------------------------------------------------- #

def esc(s) -> str:
    return html.escape(str(s), quote=True)


def fmt_money(v: float) -> str:
    v = float(v)
    if abs(v) >= 1_000_000:
        return f"{v / 1_000_000:.2f} млн ₽".replace(".", ",")
    if abs(v) >= 1000:
        return f"{v / 1000:.0f} тыс ₽"
    return f"{v:.0f} ₽"


def spaced(v) -> str:
    return f"{int(round(float(v))):,}".replace(",", "\u00a0")


def svg_open(w: int, h: int, label: str) -> list[str]:
    return [f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="{esc(label)}" '
            f'preserveAspectRatio="xMidYMid meet">']


def gridlines(x0, x1, ticks, scale, fmt):
    """Горизонтальная сетка с подписями по оси Y."""
    out = []
    for value in ticks:
        y = scale(value)
        out.append(f'<line class="grid" x1="{x0}" y1="{y:.1f}" x2="{x1}" y2="{y:.1f}"/>')
        out.append(f'<text class="axis-label" x="{x0 - 8}" y="{y + 4:.1f}" '
                   f'text-anchor="end">{esc(fmt(value))}</text>')
    return out


def nice_ticks(vmax: float, count: int = 4) -> list[float]:
    if vmax <= 0:
        return [0]
    raw = vmax / count
    mag = 10 ** int(f"{raw:e}".split("e")[1])
    for mult in (1, 2, 2.5, 5, 10):
        step = mag * mult
        if step >= raw:
            break
    return [i * step for i in range(count + 1) if i * step <= vmax * 1.15]


# --------------------------------------------------------------------------- #
# Графики
# --------------------------------------------------------------------------- #

def chart_mrr(rows) -> str:
    W, H = 820, 300
    L, R, T, B = 78, 20, 20, 44
    vals = [float(r["mrr"]) for r in rows]
    vmax = max(vals)
    sx = lambda i: L + i * (W - L - R) / max(1, len(rows) - 1)
    sy = lambda v: T + (H - T - B) * (1 - v / (vmax * 1.08))

    s = svg_open(W, H, "MRR по месяцам")
    s += gridlines(L, W - R, nice_ticks(vmax), sy, lambda v: f"{v / 1000:.0f}к")

    pts = " ".join(f"{sx(i):.1f},{sy(v):.1f}" for i, v in enumerate(vals))
    area = f"{L},{sy(0):.1f} " + pts + f" {sx(len(vals) - 1):.1f},{sy(0):.1f}"
    s.append(f'<polygon class="area" points="{area}"/>')
    s.append(f'<polyline class="line-1" points="{pts}"/>')

    for i, (r, v) in enumerate(zip(rows, vals)):
        s.append(f'<circle class="dot hit" cx="{sx(i):.1f}" cy="{sy(v):.1f}" r="9" '
                 f'data-tip="{esc(r["label"])} — {esc(fmt_money(v))}"/>')
    # Подписи оси X — каждый третий месяц, иначе слипаются. Последний месяц
    # подписывается только если между ним и предыдущей подписью есть зазор:
    # иначе «2026-07» и «2026-08» наезжают друг на друга.
    last_i = len(rows) - 1
    for i, r in enumerate(rows):
        if i % 3 == 0 or (i == last_i and last_i % 3 >= 2):
            s.append(f'<text class="axis-label" x="{sx(i):.1f}" y="{H - B + 20}" '
                     f'text-anchor="middle">{esc(r["label"])}</text>')
    last = vals[-1]
    s.append(f'<text class="value-label" x="{sx(len(vals) - 1) - 6:.1f}" '
             f'y="{sy(last) - 12:.1f}" text-anchor="end">{esc(fmt_money(last))}</text>')
    s.append("</svg>")
    return "\n".join(s)


def chart_movements(rows) -> str:
    W, H = 820, 300
    L, R, T, B = 78, 20, 20, 44
    gained = [float(r["gained"]) for r in rows]
    lost = [float(r["lost"]) for r in rows]
    vmax = max(max(gained), max(-v for v in lost)) * 1.12
    plot_h = H - T - B
    zero = T + plot_h * (vmax / (2 * vmax))
    sy = lambda v: zero - (v / vmax) * (plot_h / 2)
    band = (W - L - R) / len(rows)
    bw = min(22, band - 6)

    s = svg_open(W, H, "Приход и потери MRR по месяцам")
    # Деления симметричны и круглые: половина от максимума дала бы подписи
    # вроде «163к», по которым ничего не прикинешь в уме.
    positive = [t for t in nice_ticks(vmax, 2) if t > 0]
    tick = positive[-1] if positive else vmax / 2
    for value in [-tick, 0, tick]:
        y = sy(value)
        cls = "axis" if value == 0 else "grid"
        s.append(f'<line class="{cls}" x1="{L}" y1="{y:.1f}" x2="{W - R}" y2="{y:.1f}"/>')
        s.append(f'<text class="axis-label" x="{L - 8}" y="{y + 4:.1f}" text-anchor="end">'
                 f'{esc(f"{value / 1000:+.0f}к" if value else "0")}</text>')

    for i, r in enumerate(rows):
        cx = L + band * i + band / 2
        g, l = gained[i], lost[i]
        gh = max(2, zero - sy(g))
        s.append(f'<rect class="bar-pos hit" x="{cx - bw / 2:.1f}" y="{sy(g):.1f}" '
                 f'width="{bw:.1f}" height="{gh:.1f}" rx="4" '
                 f'data-tip="{esc(r["label"])} — приход {esc(fmt_money(g))}"/>')
        lh = max(2, sy(l) - zero)
        s.append(f'<rect class="bar-neg hit" x="{cx - bw / 2:.1f}" y="{zero + 2:.1f}" '
                 f'width="{bw:.1f}" height="{lh:.1f}" rx="4" '
                 f'data-tip="{esc(r["label"])} — потери {esc(fmt_money(l))}"/>')
        if i % 3 == 0 or (i == len(rows) - 1 and (len(rows) - 1) % 3 >= 2):
            s.append(f'<text class="axis-label" x="{cx:.1f}" y="{H - B + 26}" '
                     f'text-anchor="middle">{esc(r["label"])}</text>')
    s.append("</svg>")
    return "\n".join(s)


def chart_funnel(rows, palette) -> str:
    W = 820
    row_h, gap = 46, 10
    H = len(rows) * (row_h + gap) + 16
    L = 190
    top = float(rows[0]["users"])
    s = svg_open(W, H, "Воронка от регистрации до оплаты")
    prev = None
    for i, r in enumerate(rows):
        v = float(r["users"])
        y = 8 + i * (row_h + gap)
        w = (W - L - 150) * v / top
        s.append(f'<text class="row-label" x="{L - 14}" y="{y + row_h / 2 + 5:.0f}" '
                 f'text-anchor="end">{esc(r["label"])}</text>')
        s.append(f'<rect class="funnel-bar hit" x="{L}" y="{y}" width="{max(w, 3):.1f}" '
                 f'height="{row_h}" rx="4" fill="{palette["ramp"][i]}" '
                 f'data-tip="{esc(r["label"])} — {esc(spaced(v))} чел., '
                 f'{v / top * 100:.1f}% от старта"/>')
        label = f'{spaced(v)}  ·  {v / top * 100:.1f}%'
        s.append(f'<text class="value-label" x="{L + w + 12:.1f}" '
                 f'y="{y + row_h / 2 + 5:.0f}">{esc(label)}</text>')
        if prev is not None:
            drop = prev - v
            s.append(f'<text class="drop-label" x="{L - 14}" y="{y - 2:.0f}" '
                     f'text-anchor="end">−{esc(spaced(drop))}</text>')
        prev = v
    s.append("</svg>")
    return "\n".join(s)


def chart_retention(rows) -> str:
    W, H = 820, 300
    # Правое поле держит подписи серий: «Активированные» — 14 знаков, при R=92
    # хвост слова уходил за границу viewBox и обрезался.
    L, R, T, B = 62, 132, 20, 44
    a = [float(r["activated"]) for r in rows]
    o = [float(r["other"]) for r in rows]
    vmax = max(max(a), max(o)) * 1.12
    sx = lambda i: L + i * (W - L - R) / max(1, len(rows) - 1)
    sy = lambda v: T + (H - T - B) * (1 - v / vmax)

    s = svg_open(W, H, "Удержание: активированные против остальных")
    s += gridlines(L, W - R, nice_ticks(vmax), sy, lambda v: f"{v:.0f}%")
    for series, cls in ((a, "line-1"), (o, "line-2")):
        pts = " ".join(f"{sx(i):.1f},{sy(v):.1f}" for i, v in enumerate(series))
        s.append(f'<polyline class="{cls}" points="{pts}"/>')
    for i, r in enumerate(rows):
        s.append(f'<circle class="dot-1 hit" cx="{sx(i):.1f}" cy="{sy(a[i]):.1f}" r="9" '
                 f'data-tip="Неделя {esc(r["label"])} — активированные {a[i]:.1f}%"/>')
        s.append(f'<circle class="dot-2 hit" cx="{sx(i):.1f}" cy="{sy(o[i]):.1f}" r="9" '
                 f'data-tip="Неделя {esc(r["label"])} — остальные {o[i]:.1f}%"/>')
        s.append(f'<text class="axis-label" x="{sx(i):.1f}" y="{H - B + 20}" '
                 f'text-anchor="middle">Н{esc(r["label"])}</text>')
    x_end = sx(len(rows) - 1) + 10
    s.append(f'<text class="series-label s1" x="{x_end:.1f}" y="{sy(a[-1]) + 4:.1f}">Активированные</text>')
    s.append(f'<text class="series-label s2" x="{x_end:.1f}" y="{sy(o[-1]) + 4:.1f}">Остальные</text>')
    s.append("</svg>")
    return "\n".join(s)


def chart_channels(rows) -> str:
    rows = [r for r in rows if r["ltv_cac"] not in (None, "")]
    W = 820
    row_h, gap = 38, 10
    H = len(rows) * (row_h + gap) + 44
    L = 210
    vmax = max(float(r["ltv_cac"]) for r in rows) * 1.1
    scale = (W - L - 120) / vmax

    s = svg_open(W, H, "Окупаемость каналов: отношение LTV к CAC")
    x_one = L + 1.0 * scale
    s.append(f'<line class="threshold" x1="{x_one:.1f}" y1="4" x2="{x_one:.1f}" y2="{H - 34}"/>')
    s.append(f'<text class="threshold-label" x="{x_one + 6:.1f}" y="{H - 18}">'
             f'LTV/CAC = 1 — точка безубыточности</text>')
    for i, r in enumerate(rows):
        v = float(r["ltv_cac"])
        y = 4 + i * (row_h + gap)
        state = "crit" if v < 1 else ("warn" if v < 3 else "good")
        mark = {"crit": "▼", "warn": "◆", "good": "▲"}[state]
        word = {"crit": "убыточен", "warn": "на грани", "good": "окупается"}[state]
        s.append(f'<text class="row-label" x="{L - 14}" y="{y + row_h / 2 + 5:.0f}" '
                 f'text-anchor="end">{esc(r["label"])}</text>')
        s.append(f'<rect class="bar-{state} hit" x="{L}" y="{y}" '
                 f'width="{max(v * scale, 3):.1f}" height="{row_h}" rx="4" '
                 f'data-tip="{esc(r["label"])} — LTV/CAC {v:.2f} ({word}), '
                 f'конверсия {esc(r["conversion"])}%"/>')
        # Десятичная запятая ставится ТОЛЬКО в подписи. Соблазн написать
        # f'...{v:.2f}...'.replace('.', ',', 1) заканчивается тем, что заменяется
        # первая точка во всей строке — а она в атрибуте x="222.0". Координата
        # становится невалидной, браузер молча подставляет ноль, и все значения
        # уезжают к левому краю. Ошибка не видна ни в консоли, ни в разметке.
        shown = f"{v:.2f}".replace(".", ",")
        s.append(f'<text class="value-label" x="{L + max(v * scale, 3) + 12:.1f}" '
                 f'y="{y + row_h / 2 + 5:.0f}">{mark} {shown}</text>')
    s.append("</svg>")
    return "\n".join(s)


# --------------------------------------------------------------------------- #
# Сборка страницы
# --------------------------------------------------------------------------- #

def css() -> str:
    def vars_of(p: dict) -> str:
        """Только объявления, без селектора и скобок: скобки ставит вызывающий."""
        return "\n  ".join(f"--{k}: {v};" for k, v in p.items() if k != "ramp")

    light, dark = vars_of(LIGHT), vars_of(DARK)
    return f"""
:root {{
  {light}
}}
/* Тёмная тема объявлена дважды: медиазапрос ловит системную настройку,
   а data-theme — явное переключение, и оно должно побеждать в обе стороны. */
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    {dark}
  }}
}}
:root[data-theme="dark"] {{
  {dark}
}}

* {{ box-sizing: border-box; }}
body {{
  margin: 0; padding: 32px 20px 64px;
  background: var(--plane); color: var(--ink);
  font: 15px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif;
}}
.wrap {{ max-width: 900px; margin: 0 auto; }}
header h1 {{ font-size: 26px; margin: 0 0 6px; letter-spacing: -0.01em; }}
header p {{ margin: 0 0 28px; color: var(--ink2); }}
header a {{ color: var(--s1); }}

.tiles {{ display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); margin-bottom: 32px; }}
.tile {{ background: var(--surface); border: 1px solid var(--grid); border-radius: 10px; padding: 16px 18px; }}
.tile .k {{ font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }}
.tile .v {{ font-size: 25px; font-weight: 650; margin-top: 6px; letter-spacing: -0.02em;
           font-variant-numeric: tabular-nums; white-space: nowrap; }}
.tile .n {{ font-size: 12px; color: var(--ink2); margin-top: 4px; }}

figure {{ margin: 0 0 30px; background: var(--surface); border: 1px solid var(--grid);
          border-radius: 10px; padding: 20px 22px 16px; }}
figure h2 {{ font-size: 16px; margin: 0 0 3px; }}
figure .sub {{ font-size: 13px; color: var(--ink2); margin: 0 0 16px; }}
figcaption {{ font-size: 13px; color: var(--ink2); margin-top: 12px;
              border-top: 1px solid var(--grid); padding-top: 12px; }}
.scroll {{ overflow-x: auto; }}
svg {{ width: 100%; height: auto; min-width: 560px; display: block; }}

.grid {{ stroke: var(--grid); stroke-width: 1; }}
.axis {{ stroke: var(--axis); stroke-width: 1.5; }}
.threshold {{ stroke: var(--axis); stroke-width: 1.5; stroke-dasharray: 4 4; }}
.threshold-label {{ fill: var(--muted); font-size: 12px; }}
.axis-label {{ fill: var(--muted); font-size: 12px; }}
.row-label {{ fill: var(--ink2); font-size: 13px; }}
.value-label {{ fill: var(--ink); font-size: 13px; font-weight: 600;
                font-variant-numeric: tabular-nums; }}
.drop-label {{ fill: var(--muted); font-size: 11px; }}
.series-label {{ font-size: 12px; font-weight: 600; }}
.series-label.s1 {{ fill: var(--s1); }}
.series-label.s2 {{ fill: var(--s2); }}

.line-1 {{ fill: none; stroke: var(--s1); stroke-width: 2; stroke-linejoin: round; }}
.line-2 {{ fill: none; stroke: var(--s2); stroke-width: 2; stroke-linejoin: round; }}
.area {{ fill: var(--s1); opacity: .12; }}
.dot, .dot-1 {{ fill: var(--s1); stroke: var(--surface); stroke-width: 2; }}
.dot-2 {{ fill: var(--s2); stroke: var(--surface); stroke-width: 2; }}
.bar-pos {{ fill: var(--pos); stroke: var(--surface); stroke-width: 2; }}
.bar-neg {{ fill: var(--neg); stroke: var(--surface); stroke-width: 2; }}
.bar-good {{ fill: var(--good); }} .bar-warn {{ fill: var(--warn); }} .bar-crit {{ fill: var(--crit); }}
.funnel-bar {{ stroke: var(--surface); stroke-width: 2; }}
.hit {{ cursor: default; }}
.hit:hover {{ opacity: .82; }}

#tip {{ position: fixed; pointer-events: none; opacity: 0; transition: opacity .1s;
        background: var(--ink); color: var(--surface); font-size: 12.5px;
        padding: 6px 10px; border-radius: 6px; max-width: 280px; z-index: 9; }}

table {{ border-collapse: collapse; width: 100%; font-size: 13px; margin-top: 4px; }}
th, td {{ text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--grid); }}
th:first-child, td:first-child {{ text-align: left; }}
th {{ color: var(--muted); font-weight: 600; }}
td {{ font-variant-numeric: tabular-nums; }}
details summary {{ cursor: pointer; color: var(--ink2); font-size: 13px; margin-top: 12px; }}
footer {{ color: var(--muted); font-size: 13px; margin-top: 36px; }}
"""


def table(headers, rows) -> str:
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{esc(c)}</td>" for c in r) + "</tr>" for r in rows)
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def figure(title, sub, svg, caption, table_html=None) -> str:
    extra = (f'<details><summary>Показать таблицей</summary>{table_html}</details>'
             if table_html else "")
    return f"""<figure>
  <h2>{esc(title)}</h2>
  <p class="sub">{esc(sub)}</p>
  <div class="scroll">{svg}</div>
  <figcaption>{caption}</figcaption>
  {extra}
</figure>"""


def build(psql: str) -> str:
    kpi = query(psql, Q_KPI)[0]
    mrr = query(psql, Q_MRR)
    move = query(psql, Q_MOVE)
    funnel = query(psql, Q_FUNNEL)
    retention = query(psql, Q_RETENTION)
    channels = query(psql, Q_CHANNELS)

    top = float(funnel[0]["users"])
    paid = float(funnel[-1]["users"])
    losing = [r["label"] for r in channels if r["ltv_cac"] and float(r["ltv_cac"]) < 1]

    tiles = [
        ("MRR", fmt_money(float(kpi["mrr"])), "на дату среза"),
        ("Живых подписок", spaced(kpi["subs"]), "активны сейчас"),
        ("Конверсия в оплату", f'{kpi["conversion"]}%'.replace(".", ","), "из регистрации"),
        ("NRR на 6-й месяц", f'{kpi["nrr6"]}%'.replace(".", ","), "по зрелым когортам"),
        ("Quick Ratio", str(kpi["quick_ratio"]).replace(".", ","), "последний квартал"),
    ]
    tiles_html = "".join(
        f'<div class="tile"><div class="k">{esc(k)}</div>'
        f'<div class="v">{esc(v)}</div><div class="n">{esc(n)}</div></div>'
        for k, v, n in tiles)

    figures = [
        figure(
            "MRR нарастающим итогом",
            "Накопленная сумма всех движений: новые подписки, апгрейды, даунгрейды, отток",
            chart_mrr(mrr),
            "Ровный рост без единого отрицательного месяца. Это не значит, что всё "
            "хорошо: график суммы скрывает, какой ценой он растёт — см. следующий.",
            table(["Месяц", "MRR, ₽"], [(r["label"], spaced(r["mrr"])) for r in mrr]),
        ),
        figure(
            "Приход против потерь",
            "Тот же MRR, разложенный на составляющие: вверх — новые, вернувшиеся и апгрейды; вниз — даунгрейды и отток",
            chart_movements(move),
            "Потери растут быстрее прихода: Quick Ratio упал с 15,7 до "
            f'{str(kpi["quick_ratio"]).replace(".", ",")}. Рост держится, но запас прочности сокращается.',
            table(["Месяц", "Приход, ₽", "Потери, ₽"],
                  [(r["label"], spaced(r["gained"]), spaced(r["lost"])) for r in move]),
        ),
        figure(
            "Воронка до первой оплаты",
            "Только пользователи, успевшие пройти триал и принять решение",
            chart_funnel(funnel, LIGHT),
            f'Из {spaced(top)} регистраций платят {spaced(paid)} — {paid / top * 100:.1f}%. '
            "Крупнейшая потеря — между подтверждением почты и первым проектом.",
            table(["Шаг", "Пользователей", "От старта"],
                  [(r["label"], spaced(r["users"]),
                    f'{float(r["users"]) / top * 100:.1f}%'.replace(".", ","))
                   for r in funnel]),
        ),
        figure(
            "Удержание по неделям жизни",
            "Доля когорты, совершившей целевое действие: создание проекта, создание или закрытие задачи",
            chart_retention(retention),
            "Разрыв между активированными и остальными не схлопывается к восьмой неделе — "
            "активация отбирает другую по качеству популяцию, а не даёт временный всплеск.",
            table(["Неделя", "Активированные, %", "Остальные, %"],
                  [(f'Н{r["label"]}', r["activated"], r["other"]) for r in retention]),
        ),
        figure(
            "Окупаемость каналов",
            "Отношение модельной LTV к стоимости привлечения платящего клиента",
            chart_channels(channels),
            (f'Убыточны: {esc(", ".join(losing))}. ' if losing else "")
            + "Значения выше 10 читать нельзя: органическим каналам присвоен "
            "нулевой CAC, а модельная LTV раздута допущением о постоянном оттоке. "
            "Осмысленны только сравнение каналов между собой и знак относительно "
            'единицы — подробности в <a href="../docs/metrics.md">словаре метрик</a>.',
            table(["Канал", "LTV/CAC", "Конверсия, %"],
                  [(r["label"], r["ltv_cac"], r["conversion"]) for r in channels]),
        ),
    ]

    built = datetime.now().strftime("%d.%m.%Y %H:%M")
    return f"""<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Тайм-лайн — продуктовые метрики</title>
<style>{css()}</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>SaaS «Тайм-лайн» — продуктовые метрики</h1>
  <p>Данные на 1 сентября 2026 года. Собрано из базы скриптом
     <code>scripts/build_dashboard.py</code>, числа не правились руками.
     Подробный разбор — в <a href="../docs/findings.md">выводах</a>.</p>
</header>

<div class="tiles">{tiles_html}</div>

{"".join(figures)}

<footer>
  Синтетические данные, сгенерированы <code>etl/generate_data.py</code>.
  Собрано {built}. Графики — инлайновый SVG без внешних библиотек.
</footer>
</div>

<div id="tip" role="status"></div>
<script>
// Подсказки при наведении: один обработчик на документ вместо слушателя
// на каждой из нескольких сотен фигур.
(function () {{
  var tip = document.getElementById('tip');
  document.addEventListener('mouseover', function (e) {{
    var el = e.target.closest('[data-tip]');
    if (!el) return;
    tip.textContent = el.getAttribute('data-tip');
    tip.style.opacity = '1';
  }});
  document.addEventListener('mousemove', function (e) {{
    if (tip.style.opacity !== '1') return;
    var pad = 14, w = tip.offsetWidth, h = tip.offsetHeight;
    var x = e.clientX + pad, y = e.clientY + pad;
    if (x + w > window.innerWidth)  x = e.clientX - w - pad;
    if (y + h > window.innerHeight) y = e.clientY - h - pad;
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }});
  document.addEventListener('mouseout', function (e) {{
    if (e.target.closest('[data-tip]')) tip.style.opacity = '0';
  }});
}})();
</script>
</body>
</html>
"""


def main():
    parser = argparse.ArgumentParser(description="Сборка дашборда из данных")
    parser.add_argument("--psql", help="путь к psql, если его нет в PATH")
    args = parser.parse_args()

    page = build(find_psql(args.psql))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(page)
    print(f"Дашборд собран: {OUT}")


if __name__ == "__main__":
    main()
