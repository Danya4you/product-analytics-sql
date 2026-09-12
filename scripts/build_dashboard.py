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

# Ссылки на документацию ведут в репозиторий, а не на соседний файл.
# Относительный путь вида ../docs/findings.md работает только когда страницу
# открыли из клона: на GitHub Pages тот же путь отдаётся как text/markdown, и
# читатель видит сырой текст с решётками вместо статьи.
REPO_URL = "https://github.com/Danya4you/product-analytics-sql"
DOCS_URL = REPO_URL + "/blob/main/docs"

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
    -- Тот же период, что в разделе 3.2 отчёта: текущий квартал. Иначе плитка и
    -- таблица показывают разные числа под одним названием.
    WHERE month >= date_trunc('quarter', marts.snapshot_ts())
),
ads AS (
    SELECT
        (SELECT coalesce(sum(spend_rub), 0) FROM app.ad_spend)          AS spend,
        coalesce(sum(s.revenue_rub), 0)                                 AS revenue
    FROM marts.dim_user u
    LEFT JOIN marts.fct_subscription s ON s.user_id = u.user_id AND s.is_converted
    WHERE u.is_matured AND u.channel_group = 'paid'
),
qr_prev AS (
    SELECT round(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('new','reactivation','expansion'))
                 / nullif(abs(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('contraction','churn'))), 0), 2) AS ratio
    FROM marts.fct_mrr_movement
    WHERE month >= date_trunc('quarter', marts.snapshot_ts()) - interval '3 months'
      AND month <  date_trunc('quarter', marts.snapshot_ts())
)
SELECT live.subs, round(live.mrr) AS mrr, conv.pct AS conversion,
       nrr.pct AS nrr6, qr.ratio AS quick_ratio, qr_prev.ratio AS quick_ratio_prev,
       round(ads.revenue * 0.80 - ads.spend) AS ad_profit
FROM live, conv, nrr, qr, qr_prev, ads
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
WITH spend AS (
    SELECT c.channel_code, sum(s.spend_rub) AS spend_rub
    FROM app.ad_spend s JOIN app.channels c USING (channel_id)
    GROUP BY c.channel_code
),
cu AS (
    SELECT channel_code, channel_name, count(*) AS signups,
           count(*) FILTER (WHERE is_converted) AS paying
    FROM marts.dim_user WHERE is_matured GROUP BY channel_code, channel_name
),
cs AS (
    SELECT u.channel_code, avg(s.first_mrr_rub) AS arpu,
           count(*) FILTER (WHERE NOT s.is_active) / nullif(sum(s.tenure_months), 0) AS churn
    FROM marts.fct_subscription s JOIN marts.dim_user u USING (user_id)
    WHERE s.is_converted AND u.is_matured GROUP BY u.channel_code
)
SELECT cu.channel_name AS label,
       round(100.0 * cu.paying / cu.signups, 1) AS conversion,
       round(sp.spend_rub) AS spend,
       round(cs.arpu * 0.8 / nullif(cs.churn, 0)
             / nullif(sp.spend_rub / nullif(cu.paying, 0), 0), 2) AS ltv_cac
FROM cu
JOIN cs USING (channel_code)
JOIN spend sp USING (channel_code)
ORDER BY ltv_cac DESC NULLS FIRST
"""

Q_ATTRIBUTION = """
SELECT attribution_quality AS label, count(*) AS users,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS share
FROM marts.dim_user
GROUP BY attribution_quality
ORDER BY count(*) DESC
"""


Q_SUMMARY = """
-- Всё, что нужно блоку «Главное», одной строкой: иначе сводка собирается из
-- пяти запросов и однажды разойдётся с графиками, под которыми стоит.
WITH act AS (
    SELECT round(100.0 * count(*) FILTER (WHERE is_converted AND is_activated)
                 / nullif(count(*) FILTER (WHERE is_activated), 0), 1)        AS act_conv,
           round(100.0 * count(*) FILTER (WHERE is_converted AND NOT is_activated)
                 / nullif(count(*) FILTER (WHERE NOT is_activated), 0), 1)    AS other_conv
    FROM marts.dim_user WHERE is_matured
),
ads AS (
    SELECT count(*) AS signups, count(*) FILTER (WHERE is_converted) AS paying
    FROM marts.dim_user WHERE is_matured AND channel_group = 'paid'
),
spend AS (SELECT coalesce(sum(spend_rub), 0) AS total FROM app.ad_spend),
first_q AS (
    SELECT round(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('new','reactivation','expansion'))
                 / nullif(abs(sum(mrr_delta_rub) FILTER (WHERE movement_type IN ('contraction','churn'))), 0), 2) AS ratio
    FROM marts.fct_mrr_movement
    WHERE date_trunc('quarter', month) = (SELECT date_trunc('quarter', min(month))
                                            FROM marts.fct_mrr_movement)
),
period AS (
    SELECT count(DISTINCT month) AS months FROM marts.fct_mrr_movement
)
SELECT act.act_conv, act.other_conv, ads.signups, ads.paying,
       round(100.0 * (ads.signups - ads.paying) / nullif(ads.signups, 0), 1) AS wasted_pct,
       round(spend.total) AS spend, first_q.ratio AS qr_first, period.months
FROM act, ads, spend, first_q, period
"""

Q_TREND = """
-- Последние два ПОЛНЫХ месяца: текущий на дату среза оборван и сравнивать
-- его с предыдущим нельзя — получится падение, которого нет.
WITH m AS (
    SELECT month,
           sum(mrr_rub)                       AS mrr,
           count(*) FILTER (WHERE mrr_rub > 0) AS subs
    FROM marts.fct_subscription_month
    WHERE month < date_trunc('month', marts.snapshot_ts())
    GROUP BY month
)
SELECT to_char(month, 'YYYY-MM') AS label, round(mrr) AS mrr, subs
FROM m ORDER BY month DESC LIMIT 2
"""

Q_AB = """
WITH base AS (
    SELECT e.experiment_code, a.variant, u.user_id, u.is_activated
    FROM app.experiment_assignments a
    JOIN app.experiments e USING (experiment_id)
    JOIN marts.dim_user u ON u.user_id = a.user_id
    WHERE u.is_matured
),
onboarding AS (
    SELECT 1 AS ord,
           'Чек-лист вместо видео при первом входе'  AS experiment,
           'Освоились в первую неделю'               AS metric,
           count(*) FILTER (WHERE variant = 'control')                    AS n1,
           count(*) FILTER (WHERE variant = 'control'   AND is_activated) AS x1,
           count(*) FILTER (WHERE variant = 'treatment')                  AS n2,
           count(*) FILTER (WHERE variant = 'treatment' AND is_activated) AS x2
    FROM base WHERE experiment_code = 'onboarding_checklist_v2'
),
pricing AS (
    -- Знаменатель другой: годовой тариф может выбрать только тот, кто дошёл
    -- до оплаты. Поэтому здесь считается доля от оплативших, а не от всех.
    SELECT 2,
           'Годовая оплата выбрана по умолчанию',
           'Выбрали годовую оплату',
           count(*) FILTER (WHERE b.variant = 'control'),
           count(*) FILTER (WHERE b.variant = 'control'
                              AND s.first_billing_period = 'annual'),
           count(*) FILTER (WHERE b.variant = 'treatment'),
           count(*) FILTER (WHERE b.variant = 'treatment'
                              AND s.first_billing_period = 'annual')
    FROM base b
    JOIN marts.fct_subscription s ON s.user_id = b.user_id AND s.is_converted
    WHERE b.experiment_code = 'annual_first_pricing'
),
-- Имя combined, а не both: BOTH — зарезервированное слово (TRIM(BOTH ...)),
-- и CTE с таким именем валит разбор с невнятной ошибкой на следующей строке.
combined AS (SELECT * FROM onboarding UNION ALL SELECT * FROM pricing)
SELECT experiment, metric, n1 + n2 AS participants,
       round(100.0 * x1 / nullif(n1, 0), 1)                             AS control_pct,
       round(100.0 * x2 / nullif(n2, 0), 1)                             AS treatment_pct,
       round(100.0 * x2 / nullif(n2, 0) - 100.0 * x1 / nullif(n1, 0), 1) AS diff,
       round(marts.p_value_two_sided(
                 marts.z_two_proportions(x1, n1, x2, n2))::numeric, 4)   AS p
FROM combined ORDER BY ord
"""

Q_RISK = """
-- Правило из раздела 5.4 отчёта: сравниваем два окна по 28 дней подряд.
-- Берём подписки старше двух месяцев — у более молодых нет предыдущего окна.
WITH live AS (
    SELECT subscription_id, user_id, current_mrr_rub
    FROM marts.fct_subscription
    WHERE is_active AND tenure_days >= 56
),
activity AS (
    SELECT
        l.subscription_id,
        l.current_mrr_rub,
        coalesce(sum(a.core_actions_cnt) FILTER (
            WHERE a.activity_date > (marts.snapshot_ts() - interval '28 days')::date), 0) AS last_28,
        coalesce(sum(a.core_actions_cnt) FILTER (
            WHERE a.activity_date <= (marts.snapshot_ts() - interval '28 days')::date
              AND a.activity_date >  (marts.snapshot_ts() - interval '56 days')::date), 0) AS prev_28
    FROM live l
    LEFT JOIN marts.fct_user_activity_daily a
           ON a.user_id = l.user_id
          AND a.activity_date > (marts.snapshot_ts() - interval '56 days')::date
    GROUP BY l.subscription_id, l.current_mrr_rub
)
SELECT
    CASE WHEN last_28 = 0                THEN 'Замолчали совсем'
         WHEN last_28 < prev_28 * 0.5    THEN 'Активность упала вдвое'
         ELSE                                 'Работают как обычно' END AS label,
    count(*)                                                            AS subs,
    round(sum(current_mrr_rub))                                         AS mrr,
    round(100.0 * sum(current_mrr_rub) / sum(sum(current_mrr_rub)) OVER (), 1) AS share
FROM activity
GROUP BY 1
ORDER BY count(*)
"""

# --------------------------------------------------------------------------- #
# Примитивы SVG
# --------------------------------------------------------------------------- #

def esc(s) -> str:
    return html.escape(str(s), quote=True)


def fmt_money(v: float) -> str:
    # Минус — типографский U+2212, а не дефис: «-19,3» и «−19,3» выглядят
    # по-разному, и второе читается как число, а не как перенос.
    # Точность падает с ростом суммы: у «−19,30 млн» вторая цифра после запятой
    # создаёт ложное впечатление точности там, где её нет.
    v = float(v)
    sign = "\u2212" if v < 0 else ""
    a = abs(v)
    if a >= 10_000_000:
        return sign + f"{a / 1_000_000:.1f} млн ₽".replace(".", ",")
    if a >= 1_000_000:
        return sign + f"{a / 1_000_000:.2f} млн ₽".replace(".", ",")
    if a >= 1000:
        return sign + f"{a / 1000:.0f} тыс ₽"
    return sign + f"{a:.0f} ₽"


def plural(n, one: str, few: str, many: str) -> str:
    """Согласование существительного с числом: 1 подписка, 2 подписки, 5 подписок.

    Без этого в отчёте появляются «22 аккаунтов» и «3 человек» — мелочь, по
    которой сразу видно, что текст собран автоматически и не вычитан.
    """
    n = abs(int(n))
    if 11 <= n % 100 <= 14:
        return many
    last = n % 10
    if last == 1:
        return one
    if 2 <= last <= 4:
        return few
    return many


def short_money(v) -> str:
    """Подпись оси: «3 млн» читается, «3000к» требует расшифровки."""
    v = float(v)
    if abs(v) >= 1_000_000:
        return f"{v / 1_000_000:.1f} млн".replace(".", ",")
    if abs(v) >= 1000:
        return f"{v / 1000:.0f} тыс"
    return f"{v:.0f}"


def pct(v, dec: int = 1) -> str:
    """Процент с десятичной запятой: в русском тексте точка читается как опечатка."""
    return f"{v:.{dec}f}".replace(".", ",") + " %"


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
    s += gridlines(L, W - R, nice_ticks(vmax), sy, lambda v: short_money(v) + " ₽")

    pts = " ".join(f"{sx(i):.1f},{sy(v):.1f}" for i, v in enumerate(vals))
    area = f"{L},{sy(0):.1f} " + pts + f" {sx(len(vals) - 1):.1f},{sy(0):.1f}"
    s.append(f'<polygon class="area fade-mark" points="{area}"/>')
    s.append(f'<polyline class="line-1 draw" points="{pts}"/>')

    for i, (r, v) in enumerate(zip(rows, vals)):
        s.append(f'<circle class="dot hit fade-mark" cx="{sx(i):.1f}" cy="{sy(v):.1f}" r="9" '
                 f'style="transition-delay:{300 + i * 22}ms" '
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
                 f'{esc(("+" if value > 0 else "\u2212") + short_money(abs(value)) if value else "0")}</text>')

    for i, r in enumerate(rows):
        cx = L + band * i + band / 2
        g, l = gained[i], lost[i]
        gh = max(2, zero - sy(g))
        s.append(f'<rect class="bar-pos hit col-grow" x="{cx - bw / 2:.1f}" y="{sy(g):.1f}" '
                 f'width="{bw:.1f}" height="{gh:.1f}" rx="4" '
                 f'style="transform-origin:bottom;transition-delay:{i * 28}ms" '
                 f'data-tip="{esc(r["label"])} — приход {esc(fmt_money(g))}"/>')
        lh = max(2, sy(l) - zero)
        s.append(f'<rect class="bar-neg hit col-grow" x="{cx - bw / 2:.1f}" y="{zero + 2:.1f}" '
                 f'width="{bw:.1f}" height="{lh:.1f}" rx="4" '
                 f'style="transform-origin:top;transition-delay:{i * 28}ms" '
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
        s.append(f'<rect class="funnel-bar hit bar-grow" x="{L}" y="{y}" width="{max(w, 3):.1f}" '
                 f'height="{row_h}" rx="4" fill="{palette["ramp"][i]}" '
                 f'style="transition-delay:{i * 90}ms" '
                 f'data-tip="{esc(r["label"])} — {esc(spaced(v))} чел., '
                 f'{pct(v / top * 100)} от старта"/>')
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


def chart_attribution(rows, palette) -> str:
    """Качество атрибуции — порядковая шкала, поэтому один оттенок с градацией."""
    W = 820
    row_h, gap = 40, 10
    H = len(rows) * (row_h + gap) + 12
    L = 230
    top = max(float(r["users"]) for r in rows)
    s = svg_open(W, H, "Качество атрибуции регистраций")
    for i, r in enumerate(rows):
        v = float(r["users"])
        y = 6 + i * (row_h + gap)
        w = (W - L - 150) * v / top
        s.append(f'<text class="row-label" x="{L - 14}" y="{y + row_h / 2 + 5:.0f}" '
                 f'text-anchor="end">{esc(r["label"])}</text>')
        s.append(f'<rect class="funnel-bar hit bar-grow" x="{L}" y="{y}" width="{max(w, 3):.1f}" '
                 f'height="{row_h}" rx="4" fill="{palette["ramp"][min(i, 4)]}" '
                 f'style="transition-delay:{i * 90}ms" '
                 f'data-tip="{esc(r["label"])} — {esc(spaced(v))} регистраций, '
                 f'{esc(r["share"])}%"/>')
        shown = str(r["share"]).replace(".", ",")
        s.append(f'<text class="value-label" x="{L + max(w, 3) + 12:.1f}" '
                 f'y="{y + row_h / 2 + 5:.0f}">{esc(spaced(v))}  ·  {esc(shown)}%</text>')
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
        s.append(f'<polyline class="{cls} draw" points="{pts}"/>')
    for i, r in enumerate(rows):
        s.append(f'<circle class="dot-1 hit fade-mark" cx="{sx(i):.1f}" cy="{sy(a[i]):.1f}" r="9" '
                 f'style="transition-delay:{400 + i * 45}ms" '
                 f'data-tip="Неделя {esc(r["label"])} — активированные {a[i]:.1f}%"/>')
        s.append(f'<circle class="dot-2 hit fade-mark" cx="{sx(i):.1f}" cy="{sy(o[i]):.1f}" r="9" '
                 f'style="transition-delay:{400 + i * 45}ms" '
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
        s.append(f'<rect class="bar-{state} hit bar-grow" x="{L}" y="{y}" '
                 f'width="{max(v * scale, 3):.1f}" height="{row_h}" rx="4" '
                 f'style="transition-delay:{i * 100}ms" '
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


def chart_experiments(rows) -> str:
    """Результаты A/B-тестов: две полосы на эксперимент, контроль против теста."""
    W = 820
    bar_h, inner_gap, group_gap = 26, 8, 34
    head_h = 22
    H = len(rows) * (head_h + bar_h * 2 + inner_gap + group_gap) + 8
    L = 268
    vmax = max(max(float(r["control_pct"]), float(r["treatment_pct"])) for r in rows) * 1.35
    scale = (W - L - 130) / vmax

    s = svg_open(W, H, "Результаты A/B-тестов")
    y = 8
    for i, r in enumerate(rows):
        s.append(f'<text class="row-label" x="0" y="{y + 12}" '
                 f'style="font-weight:650">{esc(r["experiment"])}</text>')
        y += head_h
        for j, (who, key, cls) in enumerate((("Контроль", "control_pct", "line-2"),
                                             ("Тест", "treatment_pct", "line-1"))):
            v = float(r[key])
            w = max(v * scale, 3)
            fill = "var(--s2)" if j == 0 else "var(--s1)"
            s.append(f'<text class="row-label" x="{L - 14}" y="{y + bar_h / 2 + 5:.0f}" '
                     f'text-anchor="end">{esc(who)}</text>')
            s.append(f'<rect class="hit bar-grow" x="{L}" y="{y}" width="{w:.1f}" '
                     f'height="{bar_h}" rx="4" fill="{fill}" '
                     f'style="transition-delay:{(i * 2 + j) * 110}ms" '
                     f'data-tip="{esc(r["metric"])}, {esc(who.lower())}: {pct(v)}"/>')
            s.append(f'<text class="value-label" x="{L + w + 11:.1f}" '
                     f'y="{y + bar_h / 2 + 5:.0f}">{esc(pct(v))}</text>')
            y += bar_h + (inner_gap if j == 0 else 0)
        y += group_gap
    s.append("</svg>")
    return "\n".join(s)


def chart_risk(rows) -> str:
    """Сколько денег под риском: полосы по сумме MRR, цвет — состояние."""
    W = 820
    row_h, gap = 42, 12
    H = len(rows) * (row_h + gap) + 10
    L = 232
    top = max(float(r["mrr"]) for r in rows)
    states = {"Замолчали совсем": "crit", "Активность упала вдвое": "warn",
              "Работают как обычно": "good"}
    marks = {"crit": "\u25bc", "warn": "\u25c6", "good": "\u25b2"}

    s = svg_open(W, H, "Подписки в зоне риска по сумме MRR")
    for i, r in enumerate(rows):
        v = float(r["mrr"])
        y = 5 + i * (row_h + gap)
        w = max((W - L - 210) * v / top, 3)
        state = states.get(r["label"], "good")
        s.append(f'<text class="row-label" x="{L - 14}" y="{y + row_h / 2 + 5:.0f}" '
                 f'text-anchor="end">{esc(r["label"])}</text>')
        s.append(f'<rect class="bar-{state} hit bar-grow" x="{L}" y="{y}" width="{w:.1f}" '
                 f'height="{row_h}" rx="4" style="transition-delay:{i * 110}ms" '
                 f'data-tip="{esc(r["label"])}: {esc(spaced(r["subs"]))} подписок, '
                 f'{esc(fmt_money(v))} в месяц"/>')
        s.append(f'<text class="value-label" x="{L + w + 12:.1f}" '
                 f'y="{y + row_h / 2 + 5:.0f}">{marks[state]} {esc(fmt_money(v))} '
                 f'\u00b7 {esc(spaced(r["subs"]))} подписок</text>')
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
  margin: 0; padding: 40px 20px 72px;
  background: var(--plane); color: var(--ink);
  font: 15px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
  -webkit-font-smoothing: antialiased;
}}
.wrap {{ max-width: 920px; margin: 0 auto; }}

header {{ margin-bottom: 30px; }}
header h1 {{ font-size: 30px; margin: 0 0 12px; letter-spacing: -0.025em; line-height: 1.18; }}
header .lead {{ margin: 0 0 12px; color: var(--ink2); font-size: 16px; max-width: 62ch; }}
header .meta {{ margin: 0; color: var(--muted); font-size: 13px; }}
header a {{ color: var(--s1); }}

.howto {{ margin: 20px 0 0; padding: 14px 17px; border-radius: 10px;
          background: var(--surface); border: 1px solid var(--grid);
          font-size: 13.5px; color: var(--ink2); line-height: 1.65; }}
.howto b {{ color: var(--ink); font-weight: 620; }}

.tiles {{ display: grid; gap: 12px; margin: 34px 0 8px;
          grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }}
.tile {{ background: var(--surface); border: 1px solid var(--grid); border-radius: 12px;
         padding: 15px 17px 14px 19px; position: relative; overflow: hidden; }}
.tile::before {{ content: ""; position: absolute; inset: 0 auto 0 0; width: 3px;
                 background: var(--s1); opacity: .5; }}
.tile.good::before {{ background: var(--good); opacity: 1; }}
.tile.warn::before {{ background: var(--warn); opacity: 1; }}
.tile.crit::before {{ background: var(--crit); opacity: 1; }}
.tile .k {{ font-size: 12.5px; color: var(--muted); }}
.tile .v {{ font-size: 26px; font-weight: 660; margin-top: 6px; letter-spacing: -0.025em;
            font-variant-numeric: tabular-nums; white-space: nowrap; }}
.tile .n {{ font-size: 12.5px; color: var(--ink2); margin-top: 5px; line-height: 1.45; }}
/* Цвет состояния несёт точка, а не сам текст. Подпись цветом читалась плохо:
   жёлтый на светлой карточке даёт контраст 1,8:1 при норме 4,5:1, а красный
   на тёмной — 3,6:1. Цвет остался вспомогательным каналом, слово — основным. */
.tile .flag {{ display: inline-flex; align-items: center; gap: 6px; margin-top: 8px;
               font-size: 11.5px; font-weight: 620; color: var(--ink2);
               padding: 3px 9px 3px 7px; border-radius: 20px; border: 1px solid var(--grid); }}
.tile .flag::before {{ content: ""; width: 7px; height: 7px; border-radius: 50%;
                       background: var(--muted); flex: none; }}
.tile.good .flag::before {{ background: var(--good); }}
.tile.warn .flag::before {{ background: var(--warn); }}
.tile.crit .flag::before {{ background: var(--crit); }}
.tile .delta {{ font-size: 12px; color: var(--ink2); margin-top: 6px;
                font-variant-numeric: tabular-nums; }}
.tile .delta .arrow {{ font-size: 10px; }}

/* ---------- сводка ---------- */
.summary {{ margin: 34px 0 8px; padding: 24px 26px 22px; border-radius: 12px;
            background: var(--surface); border: 1px solid var(--grid);
            border-left: 3px solid var(--s1); }}
.summary h2 {{ font-size: 19px; margin: 0 0 10px; letter-spacing: -0.02em; }}
.summary .lead {{ margin: 0 0 18px; font-size: 15.5px; max-width: 66ch; }}
.summary ol {{ margin: 0; padding-left: 22px; display: grid; gap: 11px; }}
.summary li {{ font-size: 14px; color: var(--ink2); max-width: 74ch; }}
.summary li b {{ color: var(--ink); font-weight: 640; }}
.summary a {{ color: var(--s1); text-decoration: none; cursor: pointer;
              border-bottom: 1px solid color-mix(in srgb, var(--s1) 35%, transparent); }}
.summary a:hover {{ border-bottom-color: var(--s1); }}
.summary a::after {{ content: " \2193"; font-size: 11px; }}

/* Цель перехода не должна упираться в верхний край окна. */
figure, .glossary, .summary {{ scroll-margin-top: 18px; }}

/* Короткая вспышка на месте приземления: без неё после прокрутки непонятно,
   на какой именно блок смотреть. */
@keyframes landed {{
  0%   {{ box-shadow: 0 0 0 0 rgba(42, 120, 214, .00); }}
  25%  {{ box-shadow: 0 0 0 4px rgba(42, 120, 214, .38); }}
  100% {{ box-shadow: 0 0 0 0 rgba(42, 120, 214, .00); }}
}}
.landed {{ animation: landed 1.5s ease; }}
.todo {{ margin-top: 22px; padding-top: 18px; border-top: 1px solid var(--grid); }}
.todo h3 {{ font-size: 15px; margin: 0 0 12px; }}
.todo ol {{ counter-reset: none; }}
.todo li {{ color: var(--ink2); }}
.todo .cost {{ display: inline-block; font-size: 11.5px; color: var(--muted);
               border: 1px solid var(--grid); border-radius: 20px;
               padding: 1px 8px; margin-left: 6px; white-space: nowrap; }}

.section {{ font-size: 12.5px; font-weight: 650; letter-spacing: .09em;
            text-transform: uppercase; color: var(--muted);
            margin: 42px 0 16px; padding-bottom: 9px; border-bottom: 1px solid var(--grid); }}

figure {{ margin: 0 0 22px; background: var(--surface); border: 1px solid var(--grid);
          border-radius: 12px; padding: 22px 24px 18px; }}
figure h3 {{ font-size: 17.5px; margin: 0 0 6px; letter-spacing: -0.015em; }}
figure .sub {{ font-size: 13.5px; color: var(--ink2); margin: 0 0 18px; max-width: 70ch; }}
figcaption {{ font-size: 13.5px; color: var(--ink2); margin-top: 14px;
              border-top: 1px solid var(--grid); padding-top: 13px; max-width: 74ch; }}
figcaption b {{ color: var(--ink); font-weight: 620; }}
.scroll {{ overflow-x: auto; }}
svg {{ width: 100%; height: auto; min-width: 560px; display: block; }}

.term {{ border-bottom: 1px dashed var(--muted); cursor: help; }}
/* Фокус виден всегда: подсказки доступны не только мышью, но и с клавиатуры. */
:focus-visible {{ outline: 2px solid var(--s1); outline-offset: 2px; border-radius: 3px; }}
.scroll:focus-visible {{ outline-offset: -2px; }}
.hint {{ font-size: 12px; color: var(--muted); margin: 8px 0 0; }}

.grid {{ stroke: var(--grid); stroke-width: 1; }}
.axis {{ stroke: var(--axis); stroke-width: 1.5; }}
.threshold {{ stroke: var(--axis); stroke-width: 1.5; stroke-dasharray: 4 4; }}
.threshold-label {{ fill: var(--muted); font-size: 12px; }}
.axis-label {{ fill: var(--muted); font-size: 12px; }}
.row-label {{ fill: var(--ink2); font-size: 13px; }}
.value-label {{ fill: var(--ink); font-size: 13px; font-weight: 620;
                font-variant-numeric: tabular-nums; }}
.drop-label {{ fill: var(--muted); font-size: 11px; }}
.series-label {{ font-size: 12px; font-weight: 620; }}
.series-label.s1 {{ fill: var(--s1); }}
.series-label.s2 {{ fill: var(--s2); }}

.line-1 {{ fill: none; stroke: var(--s1); stroke-width: 2.2;
           stroke-linejoin: round; stroke-linecap: round; }}
.line-2 {{ fill: none; stroke: var(--s2); stroke-width: 2.2;
           stroke-linejoin: round; stroke-linecap: round; }}
.area {{ fill: var(--s1); opacity: .12; }}
.dot, .dot-1 {{ fill: var(--s1); stroke: var(--surface); stroke-width: 2; }}
.dot-2 {{ fill: var(--s2); stroke: var(--surface); stroke-width: 2; }}
.bar-pos {{ fill: var(--pos); stroke: var(--surface); stroke-width: 2; }}
.bar-neg {{ fill: var(--neg); stroke: var(--surface); stroke-width: 2; }}
.bar-good {{ fill: var(--good); }} .bar-warn {{ fill: var(--warn); }} .bar-crit {{ fill: var(--crit); }}
.funnel-bar {{ stroke: var(--surface); stroke-width: 2; }}
.hit {{ cursor: default; transition: opacity .15s; }}
.hit:hover {{ opacity: .78; }}

#tip {{ position: fixed; pointer-events: none; opacity: 0; transition: opacity .12s;
        background: var(--ink); color: var(--surface); font-size: 12.5px; line-height: 1.45;
        padding: 7px 11px; border-radius: 7px; max-width: 300px; z-index: 9;
        box-shadow: 0 4px 16px rgba(0,0,0,.18); }}

table {{ border-collapse: collapse; width: 100%; font-size: 13px; margin-top: 6px; }}
th, td {{ text-align: right; padding: 7px 10px; border-bottom: 1px solid var(--grid); }}
th:first-child, td:first-child {{ text-align: left; }}
th {{ color: var(--muted); font-weight: 620; }}
td {{ font-variant-numeric: tabular-nums; }}
details summary {{ cursor: pointer; color: var(--ink2); font-size: 13px; margin-top: 12px; }}
details[open] summary {{ margin-bottom: 6px; }}

.glossary {{ margin-top: 42px; background: var(--surface); border: 1px solid var(--grid);
             border-radius: 12px; padding: 22px 24px; }}
.glossary h3 {{ font-size: 17px; margin: 0 0 14px; }}
.glossary dl {{ margin: 0; display: grid; gap: 12px; }}
.glossary dt {{ font-weight: 650; font-size: 14px; }}
.glossary dd {{ margin: 3px 0 0; color: var(--ink2); font-size: 13.5px; max-width: 76ch; }}

footer {{ color: var(--muted); font-size: 13px; margin-top: 34px; line-height: 1.65; }}

/* ---------- печать ----------
   На бумаге нет наведения, прокрутки и тёмной темы. Карточки не должны
   разрываться между страницами, а таблицы под графиками — наоборот, должны
   быть раскрыты: на бумаге это единственный способ увидеть точные числа. */
@media print {{
  body {{ background: #fff; color: #000; padding: 0; font-size: 11pt; }}
  .wrap {{ max-width: none; }}
  #tip, .howto {{ display: none !important; }}
  figure, .tile, .glossary, .summary {{ break-inside: avoid; page-break-inside: avoid;
                                        box-shadow: none; }}
  .section {{ break-after: avoid; page-break-after: avoid; }}
  details > *:not(summary) {{ display: block !important; }}
  details summary {{ display: none; }}
  html.anim .reveal {{ opacity: 1 !important; transform: none !important; }}
  html.anim .bar-grow, html.anim .col-grow {{ transform: none !important; }}
  html.anim .draw {{ stroke-dashoffset: 0 !important; }}
  html.anim .fade-mark {{ opacity: 1 !important; }}
  svg {{ min-width: 0; }}
}}

/* ======================= анимации ======================= */
/* Класс anim ставит скрипт. Если скрипт не выполнился, всё видно сразу:
   страница не должна зависеть от JavaScript, чтобы показать содержимое.
   Всё выключается, если в системе включено «уменьшить движение». */
@media (prefers-reduced-motion: no-preference) {{
  html.anim .reveal {{ opacity: 0; transform: translateY(16px); }}
  html.anim .reveal.shown {{ opacity: 1; transform: none;
      transition: opacity .55s ease, transform .55s cubic-bezier(.22,.7,.3,1); }}

  html.anim .bar-grow {{ transform: scaleX(0); transform-box: fill-box;
                         transform-origin: left center; }}
  html.anim .shown .bar-grow {{ transform: scaleX(1);
      transition: transform .75s cubic-bezier(.22,.75,.28,1); }}

  html.anim .col-grow {{ transform: scaleY(0); transform-box: fill-box; }}
  html.anim .shown .col-grow {{ transform: scaleY(1);
      transition: transform .6s cubic-bezier(.22,.75,.28,1); }}

  html.anim .fade-mark {{ opacity: 0; }}
  html.anim .shown .fade-mark {{ opacity: 1; transition: opacity .5s ease; }}
  html.anim .shown .area.fade-mark {{ opacity: .12; }}

  html.anim .draw {{ stroke-dashoffset: var(--len); }}
  html.anim .shown .draw {{ stroke-dashoffset: 0;
      transition: stroke-dashoffset 1.15s cubic-bezier(.4,.1,.2,1); }}
}}
"""


def term(word: str, explanation: str) -> str:
    """Термин с пояснением по наведению — чтобы жаргон не отпугивал читателя."""
    return (f'<span class="term" tabindex="0" role="button" '
            f'data-tip="{esc(explanation)}">{esc(word)}</span>')


def table(headers, rows) -> str:
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = "".join("<tr>" + "".join(f"<td>{esc(c)}</td>" for c in r) + "</tr>" for r in rows)
    return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"


def figure(title, sub, svg, caption, table_html=None, anchor=None) -> str:
    extra = (f'<details><summary>Показать числами</summary>{table_html}</details>'
             if table_html else "")
    ident = f' id="{anchor}"' if anchor else ""
    return f"""<figure class="reveal"{ident}>
  <h3>{title}</h3>
  <p class="sub">{sub}</p>
  <div class="scroll" tabindex="0" role="group" aria-label="График, прокручивается по горизонтали">{svg}</div>
  <figcaption>{caption}</figcaption>
  {extra}
</figure>"""


def tile(name, value, num, dec, suffix, note, state=None, flag=None, delta=None) -> str:
    cls = f"tile reveal {state}" if state else "tile reveal"
    flag_html = f'<div class="flag">{esc(flag)}</div>' if flag else ""
    delta_html = ""
    if delta:
        # Направление показывает стрелка, а не цвет: цветной текст такого
        # размера не набирает нужного контраста ни в одной из двух тем.
        value_txt, caption = delta
        arrow = "\u25b2" if value_txt.startswith("+") else (
                "\u25bc" if value_txt.startswith("\u2212") else "\u2013")
        delta_html = (f'<div class="delta"><span class="arrow">{arrow}</span> '
                      f'{esc(value_txt)} {esc(caption)}</div>')
    return (f'<div class="{cls}"><div class="k">{esc(name)}</div>'
            f'<div class="v" data-num="{num}" data-dec="{dec}" data-suffix="{esc(suffix)}">'
            f'{esc(value)}</div>'
            f'{delta_html}'
            f'<div class="n">{note}</div>{flag_html}</div>')


def signed(v, dec: int = 1, suffix: str = "%") -> str:
    # Знак подписи всегда явный: «+3,2 %» читается иначе, чем «3,2 %».
    sign = "+" if v > 0 else ("\u2212" if v < 0 else "")
    return f"{sign}{abs(v):.{dec}f}".replace(".", ",") + suffix


GLOSSARY = [
    ("Подписка и MRR",
     "Клиент платит за пользование сервисом каждый месяц. MRR — сумма всех таких "
     "ежемесячных платежей. У годовых подписок цена делится на 12, иначе в месяц "
     "оплаты выручка подскакивала бы в двенадцать раз."),
    ("Конверсия",
     "Доля тех, кто дошёл до нужного шага. «Конверсия в оплату 19,6 %» означает, что "
     "из ста зарегистрировавшихся платить начинают около двадцати."),
    ("Пробный период и активация",
     "Первые 14 дней сервисом пользуются бесплатно. Активация — когда человек за "
     "первую неделю завёл проект и создал минимум три задачи, то есть реально начал "
     "работать, а не просто заглянул."),
    ("Когорта",
     "Группа клиентов, пришедших в один период. Их сравнивают между собой, чтобы "
     "отличить изменения в продукте от того, что просто пришли другие люди."),
    ("Удержание",
     "Сколько человек из группы продолжают пользоваться сервисом через неделю, месяц, "
     "полгода. Показывает, нужен ли продукт после первого интереса."),
    ("Отток",
     "Уход клиента: он отменил подписку или у него перестал проходить платёж. Второе "
     "встречается чаще, чем кажется, и лечится не продуктом, а повторными списаниями."),
    ("NRR",
     "Сколько денег остаётся от группы клиентов спустя время. 79 % через полгода "
     "значит, что от каждой тысячи рублей осталось 790 — часть ушла с клиентами, "
     "часть вернулась за счёт перехода оставшихся на дорогие тарифы."),
    ("CAC и LTV",
     "CAC — сколько стоило привести одного платящего клиента. LTV — сколько денег он "
     "принесёт за всё время. Отношение LTV к CAC показывает, окупается ли канал: "
     "меньше единицы — вложенное не вернётся никогда."),
    ("Атрибуция",
     "Определение источника, из которого пришёл клиент. В момент клика по рекламе "
     "аккаунта ещё нет, поэтому источник восстанавливают по следам в браузере — и у "
     "части людей следов не остаётся вовсе."),
]


def build(psql: str) -> str:
    kpi = query(psql, Q_KPI)[0]
    mrr = query(psql, Q_MRR)
    move = query(psql, Q_MOVE)
    funnel = query(psql, Q_FUNNEL)
    retention = query(psql, Q_RETENTION)
    channels = query(psql, Q_CHANNELS)
    attribution = query(psql, Q_ATTRIBUTION)
    trend = query(psql, Q_TREND)
    ab = query(psql, Q_AB)
    risk = query(psql, Q_RISK)
    summary = query(psql, Q_SUMMARY)[0]

    top = float(funnel[0]["users"])
    paid = float(funnel[-1]["users"])
    biggest_drop = max(
        ((float(funnel[i - 1]["users"]) - float(funnel[i]["users"]), funnel[i]["label"])
         for i in range(1, len(funnel))), key=lambda x: x[0])
    losing = [r["label"] for r in channels if r["ltv_cac"] and float(r["ltv_cac"]) < 1]
    unknown = next((r for r in attribution if "не определ" in r["label"].lower()), None)

    # Динамика к предыдущему полному месяцу: уровень без направления мало что
    # говорит — «2,8 млн» одинаково выглядит и на росте, и на спаде.
    delta_mrr = delta_subs = None
    if len(trend) == 2:
        cur, prev = trend[0], trend[1]
        if float(prev["mrr"]):
            delta_mrr = (signed((float(cur["mrr"]) - float(prev["mrr"]))
                                / float(prev["mrr"]) * 100),
                         "за последний полный месяц")
        delta_subs = (signed(int(cur["subs"]) - int(prev["subs"]), 0, ""),
                      "подписок за месяц")

    mrr_val = float(kpi["mrr"])
    qr = float(kpi["quick_ratio"])
    nrr = float(kpi["nrr6"])
    profit = float(kpi["ad_profit"])

    tiles = "".join([
        tile("Выручка в месяц", fmt_money(mrr_val), mrr_val / 1_000_000, 2, " млн ₽",
             f'Столько сервис получает каждый месяц от действующих подписок — это и есть '
             f'{term("MRR", "Monthly Recurring Revenue: сумма всех регулярных ежемесячных платежей")}.',
             delta=delta_mrr),
        tile("Платящих клиентов", spaced(kpi["subs"]), float(kpi["subs"]), 0, "",
             "Подписок, действующих на дату отчёта.", delta=delta_subs),
        tile("Доходят до оплаты", f'{kpi["conversion"]}%'.replace(".", ","),
             float(kpi["conversion"]), 1, "%",
             "Из зарегистрировавшихся, кто успел пройти пробный период и принять решение."),
        tile("Денег остаётся через полгода", f'{kpi["nrr6"]}%'.replace(".", ","), nrr, 1, "%",
             f'От суммы, которую та же группа платила в первый месяц '
             f'({term("NRR", "Net Revenue Retention: удержание выручки по когорте")}).',
             state="good" if nrr >= 100 else ("warn" if nrr >= 75 else "crit"),
             flag="норма" if nrr >= 100 else "ниже нормы"),
        tile("Приход против потерь", f"{qr:.2f}×".replace(".", ","), qr, 2, "×",
             f'Во столько раз новые деньги перекрывают потерянные за последний квартал '
             f'({term("Quick Ratio", "Отношение прироста MRR к его потерям. Ниже 1 — компания сжимается")}).',
             state="good" if qr >= 4 else ("warn" if qr >= 1 else "crit"),
             flag="растёт" if qr >= 1 else "сжимается",
             delta=((signed(qr - float(kpi["quick_ratio_prev"]), 2, ""),
                     "к прошлому кварталу") if kpi["quick_ratio_prev"] else None)),
        tile("Реклама", fmt_money(profit), profit / 1_000_000, 1, " млн ₽",
             "Прибыль от платных каналов за всё время с учётом затрат на них.",
             state="good" if profit > 0 else "crit",
             flag="окупается" if profit > 0 else "не окупается"),
    ])

    money_figs = [
        figure(
            "Сколько денег приносят подписки",
            "Ежемесячная выручка от всех действующих подписок, накопленным итогом: "
            "каждая точка — сумма, которую сервис получает в этом месяце.",
            chart_mrr(mrr),
            "<b>Вывод.</b> Выручка росла все двадцать месяцев без единого падения. "
            "Но график суммы не показывает, какой ценой этот рост даётся — для этого "
            "нужен следующий.",
            table(["Месяц", "Выручка в месяц, ₽"], [(r["label"], spaced(r["mrr"])) for r in mrr]),
        ),
        figure(
            "Откуда берутся и куда уходят деньги",
            "Тот же рост, разложенный на части. Вверх — новые подписки, вернувшиеся "
            "клиенты и переходы на дорогой тариф. Вниз — переходы на дешёвый тариф и "
            "ушедшие клиенты.",
            chart_movements(move),
            f"<b>Вывод.</b> Синие столбцы почти не растут, красные растут заметно: "
            f"приход перекрывает потери уже только в {str(kpi['quick_ratio']).replace('.', ',')} раза "
            f"против четырнадцати в начале периода. Компания всё ещё растёт, но запас "
            f"прочности сокращается.",
            table(["Месяц", "Приход, ₽", "Потери, ₽"],
                  [(r["label"], spaced(r["gained"]), spaced(r["lost"])) for r in move]),
            anchor="mrr-movements",
        ),
    ]

    people_figs = [
        figure(
            "Путь от регистрации до оплаты",
            "Каждая полоса — сколько человек дошли до этого шага. Серые числа слева "
            "показывают, сколько людей потерялось между шагами.",
            chart_funnel(funnel, LIGHT),
            f"<b>Вывод.</b> Из {spaced(top)} зарегистрировавшихся платят {spaced(paid)} — "
            f"{pct(paid / top * 100)}. Самая большая потеря — {spaced(biggest_drop[0])} "
            f"{plural(biggest_drop[0], 'человек', 'человека', 'человек')} "
            f"на шаге «{esc(biggest_drop[1])}»: люди подтвердили почту и не начали работать. "
            f"Это единственное место, где имеет смысл что-то менять в первую очередь.",
            table(["Шаг", "Человек", "От старта"],
                  [(r["label"], spaced(r["users"]), pct(float(r["users"]) / top * 100))
                   for r in funnel]),
            anchor="funnel",
        ),
        figure(
            "Сколько людей продолжают пользоваться",
            "Доля тех, кто на очередной неделе после регистрации создавал или закрывал "
            "задачи. Просто вход в систему не считается: заглянуть и уйти — не работа. "
            "Синяя линия — те, кто освоился в первую неделю, оранжевая — все остальные.",
            chart_retention(retention),
            "<b>Вывод.</b> Разрыв между линиями не сокращается к восьмой неделе. Значит, "
            "первая неделя не просто даёт всплеск интереса, а разделяет пришедших на две "
            "разные по качеству группы — и работать надо именно с ней.",
            table(["Неделя", "Освоились, %", "Остальные, %"],
                  [(f'Н{r["label"]}', r["activated"], r["other"]) for r in retention]),
            anchor="retention",
        ),
    ]

    unknown_txt = (f'У {esc(unknown["share"])} % регистраций источник определить не удалось.'
                   if unknown else "")
    market_figs = [
        figure(
            "Знаем ли мы, откуда пришёл клиент",
            "Источник перехода не хранится готовым — его восстанавливают по следам в "
            "браузере до регистрации. Следы остаются не всегда: мешают блокировщики, "
            "переходы из мессенджеров и потерянные при переадресации метки.",
            chart_attribution(attribution, LIGHT),
            f"<b>Вывод.</b> {unknown_txt} Этих людей нельзя ни выбросить из отчёта — тогда "
            f"доли каналов окажутся посчитаны не от всех, — ни записать в «прямые заходы»: "
            f"прямой канал раздуется на пустом месте. Поэтому они идут отдельной строкой, "
            f"а стоимость привлечения ниже считается вилкой, а не одним числом.",
            table(["Качество", "Регистраций", "Доля, %"],
                  [(r["label"], spaced(r["users"]), r["share"]) for r in attribution]),
        ),
        figure(
            "Окупается ли реклама",
            "Во сколько раз клиент приносит больше, чем стоило его привлечение. "
            "Пунктир — граница безубыточности: левее неё канал не вернёт вложенного.",
            chart_channels(channels),
            (f"<b>Вывод.</b> Убыточны: {esc(', '.join(losing))}. " if losing else "<b>Вывод.</b> ")
            + "Бесплатные каналы — поиск, блог, рекомендации — сюда не попали: расходы на "
            "них существуют (авторы, продвижение, зарплаты), но в данных их нет, а делить "
            "на ноль нечестно. Показатель модельный и завышен, поэтому смотреть стоит не на "
            "абсолютное значение, а на то, по какую сторону пунктира оказался канал.",
            table(["Канал", "Окупаемость (LTV/CAC)", "Конверсия, %"],
                  [(r["label"], str(r["ltv_cac"]).replace(".", ","), r["conversion"])
                   for r in channels]),
            anchor="channels",
        ),
    ]

    risk_alert = [r for r in risk if r["label"] != "Работают как обычно"]
    risk_mrr = sum(float(r["mrr"]) for r in risk_alert)
    risk_subs = sum(int(r["subs"]) for r in risk_alert)
    silent = next((r for r in risk if r["label"] == "Замолчали совсем"), None)

    risk_figs = [
        figure(
            "Кто может уйти в ближайший месяц",
            "У тех, кто собирается уйти, активность падает задолго до отмены. Здесь "
            "действующие подписки разложены по тому, как изменилась их работа в продукте "
            "за последний месяц по сравнению с предыдущим. Длина полосы — деньги, а не "
            "число клиентов: уход крупного клиента стоит дороже.",
            chart_risk(risk),
            f"<b>Вывод.</b> Под риском {esc(fmt_money(risk_mrr))} в месяц — это "
            f"{spaced(risk_subs)} "
            f"{plural(risk_subs, 'подписка', 'подписки', 'подписок')}. Начинать стоит "
            f"с замолчавших: {esc(spaced(silent['subs'])) if silent else 'несколько'} "
            f"{plural(silent['subs'], 'аккаунт', 'аккаунта', 'аккаунтов') if silent else ''} — "
            f"объём, который поддержка отработает за день. Оговорка: правило проверено на "
            f"прошлых уходах, а не на будущих. Прежде чем считать его рабочим, надо "
            f"зафиксировать порог и посмотреть через месяц, сколько отмеченных ушло.",
            table(["Группа", "Подписок", "MRR, ₽", "Доля MRR, %"],
                  [(r["label"], spaced(r["subs"]), spaced(r["mrr"]), r["share"]) for r in risk]),
            anchor="risk",
        ),
    ]

    def verdict(r):
        pv = float(r["p"])
        sign = "разница не случайна" if pv < 0.05 else "разницу тест не подтвердил"
        pp = "p < 0,0001" if pv < 0.0001 else "p = " + f"{pv:.4f}".replace(".", ",")
        return (f'«{esc(r["experiment"])}»: {esc(r["metric"].lower())} — '
                f'{esc(pct(float(r["control_pct"])))} против '
                f'{esc(pct(float(r["treatment_pct"])))}, {sign} ({pp}).')

    ab_figs = [
        figure(
            "Что проверяли экспериментами",
            "Два изменения проверяли честным сравнением: половине новых пользователей "
            "показывали прежнюю версию, половине — новую. Деление случайное, поэтому "
            "группы отличаются только самим изменением, а не сезоном или рекламой.",
            chart_experiments(ab),
            "<b>Вывод.</b> " + " ".join(verdict(r) for r in ab) +
            " Но «не случайна» не значит «велика»: у первого теста эффект оказался на "
            "границе того, что он вообще способен различить, и обещать такой же прирост "
            'после раскатки нельзя. Разбор с оценкой чувствительности — в '
            f'<a href="{DOCS_URL}/findings.md">выводах</a>.',
            table(["Эксперимент", "Участников", "Контроль, %", "Тест, %", "Разница, п.п."],
                  [(r["experiment"], spaced(r["participants"]), r["control_pct"],
                    r["treatment_pct"], r["diff"]) for r in ab]),
        ),
    ]

    # ---- сводный вывод -------------------------------------------------- #
    # Формулировки подстраиваются под знак показателей: если данные поменяются,
    # сводка не должна остаться утверждать обратное тому, что на графиках.
    qr_first = float(summary["qr_first"]) if summary["qr_first"] else None
    losing_spend = sum(float(r["spend"]) for r in channels
                       if r["ltv_cac"] and float(r["ltv_cac"]) < 1 and r["spend"])
    act_conv, other_conv = float(summary["act_conv"]), float(summary["other_conv"])
    times = act_conv / other_conv if other_conv else 0

    growth_line = (
        f'<b>Рост держится, но запас сокращается.</b> Приход новых денег перекрывал '
        f'потери в {esc(f"{qr_first:.1f}".replace(".", ","))} раза в начале периода и '
        f'в {esc(f"{qr:.1f}".replace(".", ","))} раза сейчас. Это обычная картина для '
        f'растущей компании, но тренд устойчивый. '
        f'<a href="#mrr-movements">Смотреть график</a>.'
    ) if qr_first else ""

    ads_line = (
        f'<b>Реклама не возвращает вложенного.</b> Из {esc(fmt_money(float(summary["spend"])))} '
        f'рекламного бюджета {esc(pct(float(summary["wasted_pct"])))} ушло на людей, которые '
        f'не заплатили. Прибыль платных каналов — {esc(fmt_money(profit))}. '
        f'<a href="#channels">Смотреть график</a>.'
        if profit < 0 else
        f'<b>Реклама окупается.</b> Прибыль платных каналов — {esc(fmt_money(profit))}. '
        f'<a href="#channels">Смотреть график</a>.'
    )

    findings = [
        f'<b>Всё решается в первую неделю.</b> Кто за семь дней завёл проект и создал '
        f'три задачи, платит в {esc(f"{times:.1f}".replace(".", ","))} раза чаще: '
        f'{esc(pct(act_conv))} против {esc(pct(other_conv))}. Дальше этот разрыв не '
        f'сокращается. <a href="#funnel">Смотреть воронку</a>.',
        ads_line,
        growth_line,
        f'<b>Часть клиентов уже уходит.</b> Активность за последний месяц упала вдвое '
        f'или прекратилась у действующих подписок на {esc(fmt_money(risk_mrr))} в месяц — '
        f'это {spaced(risk_subs)} '
        f'{plural(risk_subs, "подписка", "подписки", "подписок")}. '
        f'<a href="#risk">Смотреть список</a>.',
    ]

    verdict_lead = (
        "Сервис растёт двадцать месяцев подряд, но рост держится на новых клиентах, "
        "а не на существующих, и оплачен рекламой, которая не возвращает вложенного. "
        "Главный рычаг — первая неделя: именно там продукт теряет большинство пришедших."
        if profit < 0 else
        "Сервис растёт двадцать месяцев подряд. Главный рычаг — первая неделя: "
        "именно там продукт теряет большинство пришедших."
    )

    todo = [
        (f'Обзвонить {esc(spaced(silent["subs"]))} '
         f'{plural(silent["subs"], "аккаунт", "аккаунта", "аккаунтов")}, которые '
         f'замолчали, пока они не ушли.' if silent else
         'Обзвонить замолчавшие аккаунты, пока они не ушли.', "день работы"),
        (f'Заняться шагом «{esc(biggest_drop[1])}»: там теряется '
         f'{spaced(biggest_drop[0])} '
         f'{plural(biggest_drop[0], "человек", "человека", "человек")} — больше, чем '
         f'на всех следующих шагах вместе.', "продуктовая задача"),
        (f'Остановить убыточные каналы: на них ушло {esc(fmt_money(losing_spend))} '
         f'за период.', "решение маркетинга") if losing_spend else None,
    ]
    todo = [t for t in todo if t]

    summary_html = (
        '<section class="summary reveal">'
        '<h2>Главное</h2>'
        f'<p class="lead">{verdict_lead}</p>'
        '<ol>' + "".join(f'<li>{f}</li>' for f in findings if f) + '</ol>'
        '<div class="todo"><h3>С чего начать</h3><ol>'
        + "".join(f'<li>{t}<span class="cost">{esc(c)}</span></li>' for t, c in todo)
        + '</ol></div></section>'
    )

    glossary = "".join(f"<dt>{esc(t)}</dt><dd>{esc(d)}</dd>" for t, d in GLOSSARY)
    built = datetime.now().strftime("%d.%m.%Y %H:%M")

    return f"""<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Тайм-лайн — как живёт сервис</title>
<style>{css()}</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>«Тайм-лайн» — как живёт сервис</h1>
  <p class="lead">Отчёт о том, откуда приходят клиенты, сколько из них начинают платить,
     надолго ли остаются и окупается ли реклама. Данные за 20 месяцев, на 1 сентября 2026 года.</p>
  <p class="meta">Собрано из базы скриптом <code>scripts/build_dashboard.py</code> — числа
     не правились руками. Подробный разбор с оговорками — в <a href="{DOCS_URL}/findings.md">выводах</a>.</p>
  <div class="howto">
    <b>Как читать.</b> Слова, подчёркнутые пунктиром, — термины: наведите курсор или
    коснитесь, появится объяснение простыми словами. То же с любым столбцом и точкой на
    графике — покажет точные числа. С клавиатуры работает через Tab, закрыть — Esc.
    Под каждым графиком есть вывод одной фразой, а под ним — те же данные таблицей.
    Незнакомые сокращения собраны в <a href="#glossary">словаре внизу</a>.
  </div>
</header>

<div class="tiles">{tiles}</div>

{summary_html}

<h2 class="section">Деньги</h2>
{"".join(money_figs)}

<h2 class="section">Клиенты</h2>
{"".join(people_figs)}

<h2 class="section">Кто может уйти</h2>
{"".join(risk_figs)}

<h2 class="section">Откуда приходят клиенты</h2>
{"".join(market_figs)}

<h2 class="section">Что проверяли</h2>
{"".join(ab_figs)}

<section class="glossary reveal" id="glossary">
  <h3>Словарь</h3>
  <dl>{glossary}</dl>
</section>

<footer>
  Данные синтетические, сгенерированы <code>etl/generate_data.py</code>: это учебный кейс,
  а не отчёт настоящей компании. Собрано {built}.
  Графики нарисованы инлайновым SVG, без внешних библиотек.
  <br><a href="{REPO_URL}">Исходный код, SQL и документация на GitHub</a>.
</footer>
</div>

<div id="tip" role="status"></div>
<script>
(function () {{
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---- подсказки при наведении -------------------------------------------
  // Один обработчик на документ вместо слушателя на каждой из сотен фигур.
  // Подсказка работает тремя способами: мышью, касанием и с клавиатуры.
  // Только наведения мало: на телефоне его нет вовсе, а на подсказках держится
  // и объяснение терминов, и точные числа по столбцам.
  var tip = document.getElementById('tip');
  var pinned = null;                     // закреплена касанием или фокусом

  function show(el) {{
    tip.textContent = el.getAttribute('data-tip');
    tip.style.opacity = '1';
  }}
  function hide() {{ tip.style.opacity = '0'; pinned = null; }}

  function placeAtElement(el) {{
    var r = el.getBoundingClientRect();
    var pad = 10, w = tip.offsetWidth, h = tip.offsetHeight;
    // Нижняя граница считается через max: если окно уже подсказки (узкий экран,
    // свёрнутая панель предпросмотра), правый предел уходит в минус и подсказка
    // улетает за левый край.
    var maxX = Math.max(8, window.innerWidth - w - 8);
    var x = Math.min(Math.max(8, r.left + r.width / 2 - w / 2), maxX);
    var y = r.top - h - pad;
    if (y < 8) y = r.bottom + pad;
    y = Math.min(Math.max(8, y), Math.max(8, window.innerHeight - h - 8));
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }}

  document.addEventListener('mouseover', function (e) {{
    if (pinned) return;
    var el = e.target.closest('[data-tip]');
    if (el) show(el);
  }});
  document.addEventListener('mousemove', function (e) {{
    if (pinned || tip.style.opacity !== '1') return;
    var pad = 14, w = tip.offsetWidth, h = tip.offsetHeight;
    var x = e.clientX + pad, y = e.clientY + pad;
    if (x + w > window.innerWidth)  x = e.clientX - w - pad;
    if (y + h > window.innerHeight) y = e.clientY - h - pad;
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }});
  document.addEventListener('mouseout', function (e) {{
    if (!pinned && e.target.closest('[data-tip]')) hide();
  }});

  // касание и мышиный клик
  document.addEventListener('click', function (e) {{
    var el = e.target.closest('[data-tip]');
    if (!el) {{ hide(); return; }}
    if (pinned === el) {{ hide(); return; }}
    pinned = el; show(el); placeAtElement(el);
  }});

  // клавиатура
  document.addEventListener('focusin', function (e) {{
    var el = e.target.closest('[data-tip]');
    if (!el) return;
    pinned = el; show(el); placeAtElement(el);
  }});
  document.addEventListener('focusout', function () {{ if (pinned) hide(); }});
  document.addEventListener('keydown', function (e) {{ if (e.key === 'Escape') hide(); }});
  window.addEventListener('scroll', function () {{ if (pinned) hide(); }}, {{ passive: true }});

  // ---- переходы по внутренним ссылкам ------------------------------------
  // Штатная навигация по якорям молча не работает, когда страница открыта как
  // data:-документ или внутри песочницы просмотрщика: хеш не меняется и
  // прокрутка не происходит. Поэтому прокручиваем сами.
  //
  // Обработчик стоит ДО выхода по prefers-reduced-motion: ссылки должны
  // работать и у тех, кто отключил анимации, просто без плавности.
  document.addEventListener('click', function (e) {{
    var link = e.target.closest('a[href^="#"]');
    if (!link) return;
    var target = document.querySelector(link.getAttribute('href'));
    if (!target) return;
    e.preventDefault();
    // Цель может быть ещё не проявлена: прокрутка к невидимому блоку
    // выглядит как поломка.
    target.classList.add('shown');
    target.scrollIntoView({{ behavior: reduced ? 'auto' : 'smooth', block: 'start' }});
    target.classList.remove('landed');
    void target.offsetWidth;            // перезапуск анимации
    target.classList.add('landed');
    setTimeout(function () {{ target.classList.remove('landed'); }}, 1600);
  }});

  if (reduced) return;   // дальше только анимации — их пользователь отключил

  // Класс ставится скриптом: без JavaScript страница показывает всё сразу,
  // а не остаётся пустой из-за нулевой прозрачности.
  document.documentElement.classList.add('anim');

  // ---- линии: длину контура знает только браузер --------------------------
  document.querySelectorAll('.draw').forEach(function (el) {{
    var len = el.getTotalLength();
    el.style.setProperty('--len', len + 'px');
    el.style.strokeDasharray = len;
  }});

  // ---- появление блоков при прокрутке ------------------------------------
  function reveal(el) {{ el.classList.add('shown'); }}
  var io = window.IntersectionObserver ? new IntersectionObserver(function (entries) {{
    entries.forEach(function (en) {{
      if (!en.isIntersecting) return;
      reveal(en.target);
      io.unobserve(en.target);
      if (en.target.classList.contains('tile')) countUp(en.target.querySelector('.v'));
    }});
  }}, {{ rootMargin: '0px 0px -8% 0px', threshold: 0.12 }}) : null;

  var items = document.querySelectorAll('.reveal');
  if (!io) {{ items.forEach(showAll); return; }}
  items.forEach(function (el, i) {{
    if (el.classList.contains('tile')) el.style.transitionDelay = (i * 55) + 'ms';
    io.observe(el);
  }});

  // Страховка. Если наблюдатель не сработает — страницу печатают, снимают
  // миниатюру, отрисовывают в нестандартном окружении, — содержимое обязано
  // проявиться само. Скрытый навсегда блок хуже отсутствия анимации.
  function showAll(el) {{
    reveal(el);
    if (el.classList.contains('tile')) countUp(el.querySelector('.v'));
  }}
  setTimeout(function () {{ items.forEach(showAll); }}, 2500);

  // ---- счётчик в плитках --------------------------------------------------
  function fmt(n, dec, suffix) {{
    var t = dec > 0 ? n.toFixed(dec).replace('.', ',')
                    : Math.round(n).toLocaleString('ru-RU');
    return t.replace('-', '\u2212') + suffix;
  }}
  function countUp(el) {{
    if (!el || el.dataset.done) return;
    el.dataset.done = '1';
    var target = parseFloat(el.dataset.num);
    var dec = parseInt(el.dataset.dec, 10) || 0;
    var suffix = el.dataset.suffix || '';
    if (isNaN(target)) return;
    var t0 = null, dur = 900;
    function step(ts) {{
      if (t0 === null) t0 = ts;
      var k = Math.min(1, (ts - t0) / dur);
      var eased = 1 - Math.pow(1 - k, 3);
      el.textContent = fmt(target * eased, dec, suffix);
      if (k < 1) requestAnimationFrame(step);
      else el.textContent = fmt(target, dec, suffix);
    }}
    requestAnimationFrame(step);
  }}
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
