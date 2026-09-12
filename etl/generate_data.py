#!/usr/bin/env python3
"""Генератор синтетических данных SaaS «Тайм-лайн» для аналитического кейса.

Пишет CSV в каталог data/ — оттуда их забирает psql через \\copy (см. sql/01_load.sql).

Почему генератор, а не готовый датасет: нужны данные, в которых заранее
известна «правда» — реальные размеры эффектов, реальная разница между каналами,
реальный сигнал оттока. Тогда SQL-запросы можно проверить: они обязаны найти
то, что заложено, и не найти того, чего нет.

Зависимостей нет — только стандартная библиотека. Генерация детерминирована
(SEED), поэтому у всех, кто клонирует репозиторий, получаются те же числа.

Использование:
    python etl/generate_data.py                 # ~12 000 регистраций
    python etl/generate_data.py --users 4000    # быстрый прогон для CI
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import random
from datetime import date, datetime, timedelta

# --------------------------------------------------------------------------- #
# Параметры мира
# --------------------------------------------------------------------------- #

SEED = 20260912
START_DATE = date(2025, 1, 1)
SNAPSHOT = datetime(2026, 9, 1)          # дата выгрузки: всё после неё не существует
TRIAL_DAYS = 14

DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")

# plan_id, code, name, rank, billing_period, price_rub, seats
PLANS = [
    (1, "start_monthly",    "Старт",   1, "monthly",   690.00,  3),
    (2, "team_monthly",     "Команда", 2, "monthly",  1490.00, 10),
    (3, "business_monthly", "Бизнес",  3, "monthly",  3900.00, 30),
    (4, "start_annual",     "Старт",   1, "annual",   6900.00,  3),
    (5, "team_annual",      "Команда", 2, "annual",  14900.00, 10),
    (6, "business_annual",  "Бизнес",  3, "annual",  39000.00, 30),
]
PLAN_BY_ID = {p[0]: p for p in PLANS}
# (rank, billing_period) -> plan_id
PLAN_BY_RANK = {(p[3], p[4]): p[0] for p in PLANS}

# channel_id, code, name, group, целевой CAC, доля трафика, множитель качества
#
# Целевой CAC в базу НЕ попадает: в жизни стоимость канала не лежит колонкой в
# справочнике, а собирается из рекламных кабинетов суточными расходами. Здесь
# он нужен только чтобы сгенерировать правдоподобную таблицу app.ad_spend.
#
# Каналы direct и unknown — не источники трафика, а результаты атрибуции:
# «зашёл напрямую» и «определить не удалось». В витрине они первого класса,
# потому что молча выкидывать неатрибуцированные регистрации нельзя.
CHANNELS = [
    (1, "organic_search",  "Органический поиск",    "organic",     0.00, 0.28, 1.00),
    (2, "paid_search",     "Контекстная реклама",   "paid",     4200.00, 0.22, 0.86),
    (3, "paid_social",     "Таргет в соцсетях",     "paid",     5100.00, 0.15, 0.61),
    (4, "content",         "Блог и вебинары",       "organic",   850.00, 0.12, 1.14),
    (5, "referral",        "Реферальная программа", "referral",  300.00, 0.10, 1.46),
    (6, "partner",         "Партнёрские интеграции","referral", 2600.00, 0.07, 1.28),
    (7, "email",           "Рассылка по базе",      "organic",   120.00, 0.06, 1.04),
    (8, "direct",          "Прямой заход",          "direct",      0.00, 0.00, 1.00),
    (9, "unknown",         "Не определён",          "unknown",     0.00, 0.00, 1.00),
]
CHANNEL_BY_CODE = {c[1]: c for c in CHANNELS}

# Кампании платных каналов: в рекламном кабинете расходы разложены по ним,
# и это единственная гранулярность, на которой расход вообще можно сопоставить
# с регистрациями.
CAMPAIGNS = {
    "paid_search": ["brand", "generic-taskmanager", "competitor", "retargeting"],
    "paid_social": ["lookalike-smb", "interest-pm", "video-awareness"],
    "partner":     ["integration-crm", "marketplace-listing"],
}

# Почтовые домены. Корпоративный домен — единственный способ отличить компанию
# от частника, а служебные аккаунты сотрудников — по домену самой компании.
FREE_MAIL = ["gmail.com", "mail.ru", "yandex.ru", "outlook.com", "icloud.com", "bk.ru"]
CORP_WORDS = ["altair", "vektor", "sibinvest", "nordtech", "grandstroy", "medialine",
              "profkom", "uraltrade", "logistpro", "finexpert", "agrosnab", "teplodom",
              "citrus", "kvantum", "orbita", "poliplast", "rosmet", "sfera-it"]
STAFF_DOMAIN = "timeline.ru"

# Окно, в котором мобильный клиент слал task_create вместо task_created.
# Ровно так выглядит разъехавшийся трекинг после релиза: метрика проседает,
# продукт не менялся, а причина — переименованное событие.
TRACKING_BUG_START = datetime(2026, 1, 15)
TRACKING_BUG_END = datetime(2026, 2, 6)

COUNTRIES = [("RU", 0.82), ("KZ", 0.07), ("BY", 0.06), ("UZ", 0.03), ("AM", 0.02)]

COMPANY_SIZES = [("1", 0.24), ("2-10", 0.38), ("11-50", 0.22), ("51-200", 0.11), ("200+", 0.05)]

# распределение тарифов по размеру компании: rank -> вес
PLAN_MIX = {
    "1":      {1: 0.75, 2: 0.22, 3: 0.03},
    "2-10":   {1: 0.42, 2: 0.50, 3: 0.08},
    "11-50":  {1: 0.12, 2: 0.62, 3: 0.26},
    "51-200": {1: 0.04, 2: 0.45, 3: 0.51},
    "200+":   {1: 0.02, 2: 0.30, 3: 0.68},
}

CANCEL_REASONS = [
    ("too_expensive", 0.26), ("missing_features", 0.22), ("switched_to_competitor", 0.15),
    ("no_longer_needed", 0.20), ("payment_failed", 0.11), ("other", 0.06),
]

# помесячный риск оттока по сроку жизни подписки (месячные тарифы)
CHURN_HAZARD = {1: 0.115, 2: 0.092, 3: 0.076, 4: 0.066, 5: 0.058}
CHURN_HAZARD_TAIL = 0.047
ANNUAL_RENEWAL_CHURN = 0.28

ACTIVITY_EVENTS = [
    ("session_start", 0.34), ("task_created", 0.22), ("task_completed", 0.17),
    ("comment_added", 0.10), ("report_viewed", 0.07), ("file_uploaded", 0.06),
    ("project_created", 0.03), ("invite_sent", 0.01),
]
PLATFORMS = [("web", 0.74), ("mobile", 0.21), ("api", 0.05)]

# A/B-эксперименты: (id, code, name, hypothesis, primary_metric, start, end)
EXPERIMENTS = [
    (1, "onboarding_checklist_v2",
     "Чек-лист онбординга v2",
     "Пошаговый чек-лист вместо приветственного видео доведёт больше новых пользователей "
     "до первого проекта и трёх задач в первую неделю",
     "activation_rate",
     datetime(2026, 2, 1), datetime(2026, 4, 15)),
    (2, "annual_first_pricing",
     "Годовой тариф по умолчанию",
     "Если на странице тарифов по умолчанию выбран годовой период, вырастет доля годовых "
     "подписок и денежный поток, а конверсия в оплату не пострадает",
     "annual_share",
     # Окно длиннее, чем у первого теста, намеренно: основная метрика здесь
     # считается не от всех попавших в эксперимент, а только от оплативших,
     # то есть от каждого пятого. Чтобы набрать ту же мощность, нужно
     # примерно впятеро больше трафика — и это решение принимают ДО запуска,
     # а не после того, как тест закончился «ничем».
     datetime(2026, 4, 20), datetime(2026, 8, 25)),
]

rng = random.Random(SEED)

# Отдельный поток случайных чисел для дефектов данных. Это не украшательство:
# у random.Random одна последовательность на объект, и любой лишний вызов
# сдвигает всё, что берётся после него. Если бы дубли и служебные аккаунты
# тянули числа из общего rng, добавление грязи переписало бы весь набор данных
# и все числа в docs/findings.md разом устарели бы. С отдельным потоком
# основная генерация не замечает, что рядом кто-то портит данные.
dirt_rng = random.Random(SEED + 977)

# Доля событий, продублированных ретраями трекера
DUPLICATE_SHARE = 0.018
INTERNAL_ACCOUNTS = 40
# Доля пользователей, у которых ни одного маркетингового касания не сохранилось:
# заблокированные куки, потерянные метки при редиректе, заход из мессенджера.
LOST_ATTRIBUTION_SHARE = 0.22
# Доля ушедших добровольно, кто ответил на опрос о причине
SURVEY_RESPONSE_RATE = 0.45
BOT_DEVICES = 60


# --------------------------------------------------------------------------- #
# Вспомогательное
# --------------------------------------------------------------------------- #

def pick(weighted):
    """Выбор элемента из списка пар (значение, вес)."""
    total = sum(w for _, w in weighted)
    x = rng.random() * total
    upto = 0.0
    for value, w in weighted:
        upto += w
        if x <= upto:
            return value
    return weighted[-1][0]


def pick_dict(weights: dict):
    return pick(list(weights.items()))


def ts(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def clip(x, lo, hi):
    return max(lo, min(hi, x))


def business_hour(day: date) -> datetime:
    """Правдоподобное время внутри суток: пик в рабочие часы."""
    hour = int(clip(rng.gauss(14, 3.6), 0, 23))
    return datetime(day.year, day.month, day.day, hour, rng.randrange(60), rng.randrange(60))


def add_months(dt: datetime, months: int) -> datetime:
    month = dt.month - 1 + months
    year = dt.year + month // 12
    month = month % 12 + 1
    day = min(dt.day, [31, 29 if year % 4 == 0 and (year % 100 != 0 or year % 400 == 0) else 28,
                       31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1])
    return dt.replace(year=year, month=month, day=day)


def event_uid(event_id: int, user_id: int) -> str:
    """Идемпотентный ключ события, каким его присылает клиент.

    Настоящие трекеры шлют такой ключ вместе с событием именно затем, чтобы
    повторная доставка не превратилась в второе событие. По нему и дедуплицируют:
    ключ переживает ретрай, а идентификатор строки в хранилище — нет.
    """
    return f"{event_id:08x}-{user_id:06x}"


def ingest_time(occurred: datetime) -> datetime:
    """Когда событие доехало до хранилища.

    Обычно секунды, иногда минуты, изредка — несколько суток: мобильный клиент
    копил события офлайн, очередь встала, выгрузка перезапускалась. Из-за этого
    отчёт за вчера, построенный вчера, и он же, построенный сегодня, дают разные
    числа — и это не ошибка, а свойство данных.
    """
    r = dirt_rng.random()
    if r < 0.93:
        lag = timedelta(seconds=dirt_rng.uniform(1, 90))
    elif r < 0.99:
        lag = timedelta(minutes=dirt_rng.uniform(5, 600))
    else:
        lag = timedelta(days=dirt_rng.uniform(1, 5))
    return min(occurred + lag, SNAPSHOT - timedelta(seconds=1))


def survey_answer() -> str:
    """Причина отмены в том виде, в каком она приходит из формы опроса.

    Отвечает меньше половины ушедших — остальные закрывают окно. Ответы не
    нормализованы: часть выбирает пункт списка, часть пишет руками, и в базу
    падает то, что упало. Приводить это к единому виду — работа витрины, а не
    аналитического запроса, иначе каждый отчёт нормализует по-своему.
    """
    if rng.random() > SURVEY_RESPONSE_RATE:
        return ""
    reason = pick([(r, w) for r, w in CANCEL_REASONS if r != "payment_failed"])
    style = rng.random()
    if style < 0.62:
        return reason
    if style < 0.74:
        return reason.upper()
    if style < 0.84:
        return f"  {reason} "
    if style < 0.93:
        return reason.replace("_", " ")
    return {"too_expensive": "дорого", "missing_features": "нет нужных функций",
            "switched_to_competitor": "перешли к конкуренту",
            "no_longer_needed": "больше не нужно",
            "other": "другое"}.get(reason, reason)


def mrr_of(plan_id: int) -> float:
    plan = PLAN_BY_ID[plan_id]
    return round(plan[5] / 12, 2) if plan[4] == "annual" else plan[5]


# --------------------------------------------------------------------------- #
# Поток регистраций
# --------------------------------------------------------------------------- #

def signup_schedule(target_users: int):
    """Сколько регистраций приходит в каждый день периода.

    Заложены три сезонности: рост бизнеса, будни против выходных и летний спад.
    """
    days = (SNAPSHOT.date() - START_DATE).days
    month_factor = {1: 0.84, 2: 1.02, 3: 1.06, 4: 1.03, 5: 0.96, 6: 0.90,
                    7: 0.78, 8: 0.82, 9: 1.10, 10: 1.12, 11: 1.08, 12: 0.88}
    raw = []
    for i in range(days):
        day = START_DATE + timedelta(days=i)
        growth = 0.55 + 0.95 * (i / days)            # рост потока почти в три раза
        weekday = [1.16, 1.18, 1.15, 1.12, 0.98, 0.52, 0.46][day.weekday()]
        noise = rng.gauss(1.0, 0.14)
        raw.append((day, max(0.05, growth * weekday * month_factor[day.month] * noise)))

    scale = target_users / sum(w for _, w in raw)
    schedule = []
    carry = 0.0
    for day, w in raw:
        exact = w * scale + carry
        n = int(exact)
        carry = exact - n
        if n:
            schedule.append((day, n))
    return schedule


# --------------------------------------------------------------------------- #
# Основная генерация
# --------------------------------------------------------------------------- #

def generate(target_users: int):
    users, subs, sub_events, payments = [], [], [], []
    events, assignments, touchpoints = [], [], []

    ids = {"sub": 0, "sub_event": 0, "payment": 0, "event": 0,
           "device": 0, "touchpoint": 0}
    paid_signups = {}          # (день, канал) -> регистраций, для расчёта расходов
    ad_spend = []

    def next_id(key):
        ids[key] += 1
        return ids[key]

    def new_device():
        return f"d{next_id('device'):07d}"

    def log_event(user, when, name, platform=None, device=None, anonymous=False):
        """Событие в сыром логе.

        Три вещи, которых не было в идеальной версии:
          • устройство — по нему потом склеивают анонимные сессии с аккаунтом;
          • user_id может быть пустым: до входа в аккаунт продукт не знает, кто это;
          • в окне сломанного трекинга мобильные события приезжают под другим именем.
        """
        if when >= SNAPSHOT:
            return
        platform = platform or pick(PLATFORMS)
        if device is None:
            device = user["devices"][0] if len(user["devices"]) == 1 or rng.random() < 0.82                      else user["devices"][-1]
        if (name == "task_created" and platform == "mobile"
                and TRACKING_BUG_START <= when < TRACKING_BUG_END):
            name = "task_create"
        eid = next_id("event")
        uid = "" if anonymous else user["id"]
        events.append((eid, event_uid(eid, user["id"]), device, uid, ts(when),
                       ts(ingest_time(when)), name, platform))

    # ---- профиль пользователя -------------------------------------------- #

    def make_user(user_id, signed_up_at):
        # Истинный канал существует, но в базу НЕ попадает: продукт его не знает.
        # Всё, что остаётся аналитику, — следы касаний на устройствах.
        channel = pick([(c, c[5]) for c in CHANNELS if c[5] > 0])
        company_size = pick(COMPANY_SIZES)
        p_corp = {"1": 0.12, "2-10": 0.38, "11-50": 0.62,
                  "51-200": 0.78, "200+": 0.88}[company_size]
        if rng.random() < p_corp:
            domain = f"{pick([(w, 1) for w in CORP_WORDS])}.ru"
        else:
            domain = pick([(d, 1) for d in FREE_MAIL])

        devices = [new_device()]
        if rng.random() < 0.18:                   # рабочий ноутбук плюс телефон
            devices.append(new_device())

        users.append((user_id, ts(signed_up_at), pick(COUNTRIES), company_size, domain))
        if channel[1] in CAMPAIGNS:
            key = (signed_up_at.date(), channel[1])
            paid_signups[key] = paid_signups.get(key, 0) + 1
        user = {"id": user_id, "signed_up_at": signed_up_at, "channel": channel,
                "company_size": company_size, "is_b2b": domain not in FREE_MAIL,
                "devices": devices}
        make_touchpoints(user)

        # Человек ходит по сайту до того, как завёл аккаунт. Продукт в этот
        # момент знает только устройство, поэтому user_id у таких событий пуст.
        for _ in range(rng.randrange(0, 4)):
            when = signed_up_at - timedelta(hours=rng.uniform(0.1, 72))
            log_event(user, when, pick([("page_view", 0.7), ("pricing_viewed", 0.3)]),
                      device=devices[0], anonymous=True)
        return user

    # ---- маркетинговые касания до регистрации ----------------------------- #

    def make_touchpoints(user):
        """След, который канал оставляет в трекере до регистрации.

        Касания привязаны к УСТРОЙСТВУ, а не к пользователю: в момент клика по
        рекламе аккаунта ещё нет. Связать одно с другим — отдельная задача,
        которую решает marts.stg_events.

        У части пользователей не сохраняется ничего: куки заблокированы, метки
        потерялись на редиректе, переход пришёл из мессенджера. Такие
        регистрации навсегда останутся неатрибуцированными, и это не чинится
        запросом — это свойство сбора данных.
        """
        if rng.random() < LOST_ATTRIBUTION_SHARE:
            return

        device = user["devices"][0]
        signup = user["signed_up_at"]
        true_channel = user["channel"]

        # Путь до регистрации редко состоит из одного касания: человек увидел
        # статью, потом рекламу, потом пришёл по ссылке от коллеги. Именно из-за
        # этой цепочки модели атрибуции и расходятся — first touch назовёт
        # начало цепочки, last non-direct click её конец.
        for _ in range(rng.randrange(0, 5)):
            when = signup - timedelta(days=rng.uniform(0.5, 45), hours=rng.uniform(0, 24))
            if rng.random() < 0.38:
                ch = CHANNEL_BY_CODE["direct"]
            else:
                ch = pick([(c, c[5]) for c in CHANNELS if c[5] > 0])
            add_touchpoint(device, when, ch)

        # Решающее касание — то, из которого человек и пришёл. Но в 8 % случаев
        # именно оно и теряется: переход по рекламе прошёл через редирект,
        # который срезал метки. Тогда модель атрибуции уверенно назовёт канал —
        # и ошибётся, потому что назовёт соседнее касание. Проверить это по
        # данным нельзя, поэтому в отчётах и нужна оговорка про модель.
        if rng.random() >= 0.08:
            add_touchpoint(device, signup - timedelta(hours=rng.uniform(0.05, 60)),
                           true_channel)

        # часть людей после этого ещё раз заходит напрямую, уже решившись
        if rng.random() < 0.3:
            add_touchpoint(device, signup - timedelta(minutes=rng.uniform(1, 240)),
                           CHANNEL_BY_CODE["direct"])

    def add_touchpoint(device, when, channel):
        if when >= SNAPSHOT:
            return
        campaign = ""
        if channel[1] in CAMPAIGNS:
            campaign = pick([(c, 1) for c in CAMPAIGNS[channel[1]]])
        touchpoints.append((next_id("touchpoint"), device, ts(when), channel[0],
                            campaign, "true" if channel[1] == "direct" else "false"))

    # ---- назначение в эксперимент ---------------------------------------- #

    def assign_experiments(user):
        variants = {}
        for exp_id, _code, _name, _hyp, _metric, start, end in EXPERIMENTS:
            if start <= user["signed_up_at"] < end:
                variant = "treatment" if rng.random() < 0.5 else "control"
                variants[exp_id] = variant
                assignments.append((exp_id, user["id"], variant, ts(user["signed_up_at"])))
        return variants

    # ---- воронка первых 14 дней ------------------------------------------ #

    def run_onboarding(user, variants):
        """Воронка первой недели.

        Возвращает состояние пользователя на конец окна активации: докуда он
        дошёл и активировался ли. Глубина прохождения нужна не только для
        отчётов — от неё зависит, будет ли у человека вообще активность дальше.
        Тот, кто не подтвердил почту, в продукт не заходил ни разу, и рисовать
        ему события второй недели нельзя: кривая удержания станет красивой и
        неправдоподобной.
        """
        quality = user["channel"][6]
        t0 = user["signed_up_at"]
        log_event(user, t0, "signup", "web")

        p_confirm = clip(0.88 * (0.94 + 0.06 * quality), 0, 0.97)
        if rng.random() > p_confirm:
            return {"confirmed": False, "onboarded": False, "project": False,
                    "tasks": 0, "activated": False}
        log_event(user, t0 + timedelta(minutes=rng.randrange(3, 220)), "email_confirmed", "web")

        p_onboarding = clip(0.60 * quality, 0.05, 0.95)
        if variants.get(1) == "treatment":
            p_onboarding = clip(p_onboarding * 1.20, 0.05, 0.95)   # заложенный эффект A/B №1
        onboarding_done = rng.random() < p_onboarding
        if onboarding_done:
            log_event(user, t0 + timedelta(hours=rng.uniform(0.2, 30)), "onboarding_completed", "web")

        p_project = 0.90 if onboarding_done else 0.33
        if rng.random() > p_project:
            return {"confirmed": True, "onboarded": onboarding_done, "project": False,
                    "tasks": 0, "activated": False}
        project_at = t0 + timedelta(hours=rng.uniform(0.3, 96 if onboarding_done else 140))
        log_event(user, project_at, "project_created", "web")

        # Задачи первой недели. Окно жёстко ограничено седьмым днём от регистрации:
        # активация определяется именно на этом окне, и определение в SQL
        # (sql/marts/10_dim_user.sql) должно совпадать с заложенным здесь.
        window_end = t0 + timedelta(days=7)
        lam = (5.2 if onboarding_done else 1.9) * (1.15 if user["is_b2b"] else 1.0)
        n_tasks = max(0, int(rng.gauss(lam, lam * 0.55)))
        for _ in range(n_tasks):
            if project_at < window_end:
                span = (window_end - project_at).total_seconds()
                when = project_at + timedelta(seconds=rng.uniform(60, span))
            else:
                when = project_at + timedelta(hours=rng.uniform(0.1, 72))
            log_event(user, when, "task_created")

        if user["is_b2b"] and rng.random() < 0.47:
            log_event(user, project_at + timedelta(hours=rng.uniform(1, 24 * 8)), "invite_sent", "web")
        if rng.random() < (0.22 if onboarding_done else 0.06):
            log_event(user, project_at + timedelta(hours=rng.uniform(2, 24 * 10)), "integration_connected", "api")

        activated = n_tasks >= 3 and project_at <= window_end
        return {"confirmed": True, "onboarded": onboarding_done, "project": True,
                "tasks": n_tasks, "activated": activated}

    # ---- жизненный цикл подписки ----------------------------------------- #

    def run_subscription(user, variants, activated, is_reactivation=False):
        sub_id = next_id("sub")
        trial_start = user["signed_up_at"]
        trial_end = trial_start + timedelta(days=TRIAL_DAYS)
        quality = user["channel"][6]

        sub_events.append((next_id("sub_event"), sub_id, ts(trial_start), "trial_start",
                           PLAN_BY_RANK[(2, "monthly")], 0, 0))

        # вероятность оплаты после триала
        p_convert = (0.335 if activated else 0.068) * quality
        if user["is_b2b"]:
            p_convert *= 1.16
        if is_reactivation:
            p_convert *= 1.9                      # вернувшиеся знают, за что платят
        p_convert = clip(p_convert, 0.01, 0.82)

        started_at = trial_end + timedelta(hours=rng.uniform(-18, 30))
        # оплата после даты среза невозможна: её ещё не случилось на момент выгрузки
        converts = started_at < SNAPSHOT and rng.random() < p_convert

        if not converts:
            status = "trial" if trial_end >= SNAPSHOT else "trial_expired"
            subs.append((sub_id, user["id"], PLAN_BY_RANK[(2, "monthly")], ts(trial_start),
                         ts(trial_end), "", "", status, "", 1))
            # Кто не оплатил, обычно не исчезает ровно в день окончания триала:
            # часть дотягивает ещё несколько дней на остатках доступа.
            leaves_at = trial_end + timedelta(days=rng.uniform(0, 4))
            return {"trial_start": trial_start, "trial_end": min(leaves_at, SNAPSHOT), "paid": None}

        # выбор тарифа
        rank = pick_dict(PLAN_MIX[user["company_size"]])
        p_annual = 0.30 if rank == 3 else 0.20
        if variants.get(2) == "treatment":
            p_annual = clip(p_annual * 1.75, 0, 0.9)               # заложенный эффект A/B №2
        period = "annual" if rng.random() < p_annual else "monthly"
        plan_id = PLAN_BY_RANK[(rank, period)]
        seats = {"1": 1, "2-10": rng.randrange(2, 7), "11-50": rng.randrange(5, 18),
                 "51-200": rng.randrange(12, 45), "200+": rng.randrange(30, 120)}[user["company_size"]]

        mrr = mrr_of(plan_id)
        sub_events.append((next_id("sub_event"), sub_id, ts(started_at), "convert", plan_id, 0, mrr))

        # ---- помесячный цикл ---- #
        cursor = started_at
        period_index = 0
        ended_at = None
        cancel_reason = ""
        current_plan = plan_id
        step_months = 12 if period == "annual" else 1

        while True:
            period_index += 1
            plan = PLAN_BY_ID[current_plan]
            amount = plan[5]

            # платёж за период
            if cursor < SNAPSHOT:
                if rng.random() < 0.962:
                    payments.append((next_id("payment"), sub_id, ts(cursor), f"{amount:.2f}", "succeeded", 1))
                    if rng.random() < 0.004:
                        refund_at = cursor + timedelta(days=rng.randrange(1, 14))
                        if refund_at < SNAPSHOT:
                            payments.append((next_id("payment"), sub_id, ts(refund_at),
                                             f"{-amount:.2f}", "refunded", 1))
                else:
                    payments.append((next_id("payment"), sub_id, ts(cursor), f"{amount:.2f}", "failed", 1))
                    retry_at = cursor + timedelta(days=1, hours=rng.uniform(0, 6))
                    if rng.random() < 0.62:
                        if retry_at < SNAPSHOT:
                            payments.append((next_id("payment"), sub_id, ts(retry_at),
                                             f"{amount:.2f}", "succeeded", 2))
                    else:
                        if retry_at < SNAPSHOT:
                            payments.append((next_id("payment"), sub_id, ts(retry_at),
                                             f"{amount:.2f}", "failed", 2))
                        # Пассивный отток: клиент ничего не отменял, просто не
                        # прошло списание. Формы отмены он не видел, поэтому
                        # причина остаётся пустой — как и в жизни.
                        ended_at, cancel_reason = retry_at, ""
                        break

            next_cursor = add_months(cursor, step_months)
            if next_cursor >= SNAPSHOT:
                break

            # смена тарифа внутри периода
            if period == "monthly" and rng.random() < (0.026 if activated else 0.010):
                new_rank = min(3, plan[3] + 1)
                if new_rank != plan[3]:
                    new_plan = PLAN_BY_RANK[(new_rank, period)]
                    change_at = cursor + timedelta(days=rng.uniform(1, 25))
                    if change_at < SNAPSHOT:
                        sub_events.append((next_id("sub_event"), sub_id, ts(change_at), "upgrade",
                                           new_plan, mrr_of(current_plan), mrr_of(new_plan)))
                        current_plan = new_plan
            elif period == "monthly" and rng.random() < 0.013:
                new_rank = max(1, plan[3] - 1)
                if new_rank != plan[3]:
                    new_plan = PLAN_BY_RANK[(new_rank, period)]
                    change_at = cursor + timedelta(days=rng.uniform(1, 25))
                    if change_at < SNAPSHOT:
                        sub_events.append((next_id("sub_event"), sub_id, ts(change_at), "downgrade",
                                           new_plan, mrr_of(current_plan), mrr_of(new_plan)))
                        current_plan = new_plan

            # риск оттока на границе периода
            if period == "annual":
                hazard = ANNUAL_RENEWAL_CHURN
            else:
                hazard = CHURN_HAZARD.get(period_index, CHURN_HAZARD_TAIL)
            hazard *= 0.62 if activated else 1.0
            hazard *= 0.82 if user["is_b2b"] else 1.0
            hazard *= 1.28 if user["company_size"] == "1" else 1.0

            if rng.random() < hazard:
                ended_at = next_cursor - timedelta(hours=rng.uniform(1, 40))
                cancel_reason = survey_answer()
                break

            sub_events.append((next_id("sub_event"), sub_id, ts(next_cursor), "renew",
                               current_plan, mrr_of(current_plan), mrr_of(current_plan)))
            cursor = next_cursor

        if ended_at is not None:
            sub_events.append((next_id("sub_event"), sub_id, ts(ended_at), "cancel",
                               current_plan, mrr_of(current_plan), 0))

        status = "churned" if ended_at else "active"
        subs.append((sub_id, user["id"], current_plan, ts(trial_start), ts(trial_end),
                     ts(started_at), ts(ended_at) if ended_at else "", status, cancel_reason, seats))
        return {"trial_start": trial_start, "trial_end": started_at,
                "paid": (started_at, ended_at, current_plan)}

    # ---- продуктовая активность в платном периоде ------------------------ #

    def run_activity(user, activated, start, finish, rank=2, scale=1.0,
                     fade_before=None, fade_days=28):
        """Поток продуктовых событий на отрезке [start, finish).

        Перед уходом активность падает — это главный сигнал, который потом
        ищет запрос 05_churn_drivers. Отрезок начинается не раньше восьмого дня
        жизни: первые семь дней целиком описаны воронкой онбординга, и лишние
        task_created там сломали бы определение активации.
        """
        start = max(start, user["signed_up_at"] + timedelta(days=7))
        finish = min(finish, SNAPSHOT)
        if finish <= start:
            return

        base = (2.4 + 1.5 * rank) * (1.55 if activated else 0.85) * scale * rng.uniform(0.6, 1.4)
        week = start
        while week < finish:
            intensity = base * math.exp(-0.012 * ((week - start).days / 7))  # затухание интереса
            if fade_before and (fade_before - week).days <= fade_days:
                intensity *= 0.38
            n = max(0, int(rng.gauss(intensity, intensity * 0.5)))
            for _ in range(n):
                when = week + timedelta(days=rng.uniform(0, 7))
                if when < finish:
                    log_event(user, when, pick(ACTIVITY_EVENTS))
            week += timedelta(days=7)

    # во что превращается глубина воронки: множитель интенсивности на триале
    TRIAL_ENGAGEMENT = {"none": 0.0, "confirmed": 0.18, "project": 0.5, "activated": 1.0}

    def run_lifecycle_activity(user, funnel, life):
        """Активность за весь жизненный цикл: сначала триал, потом платный период."""
        if not funnel["confirmed"]:
            stage = "none"          # в продукт так и не зашли
        elif not funnel["project"]:
            stage = "confirmed"     # зашли, посмотрели, ничего не завели
        elif not funnel["activated"]:
            stage = "project"
        else:
            stage = "activated"

        activated = funnel["activated"]
        run_activity(user, activated, user["signed_up_at"], life["trial_end"],
                     rank=2, scale=0.7 * TRIAL_ENGAGEMENT[stage],
                     fade_before=None if life["paid"] else life["trial_end"], fade_days=5)

        if life["paid"]:
            started_at, ended_at, plan_id = life["paid"]
            run_activity(user, activated, started_at, ended_at or SNAPSHOT,
                         rank=PLAN_BY_ID[plan_id][3], scale=1.0, fade_before=ended_at)

    # ---- прогон ----------------------------------------------------------- #

    user_id = 0
    reactivation_queue = []          # (дата новой регистрации, профиль)

    for day, n in signup_schedule(target_users):
        # сначала реактивации, назначенные на этот день
        while reactivation_queue and reactivation_queue[0][0].date() <= day:
            when, profile = reactivation_queue.pop(0)
            profile = dict(profile, signed_up_at=when)
            variants = assign_experiments(profile)
            funnel = run_onboarding(profile, variants)
            life = run_subscription(profile, variants, funnel["activated"], is_reactivation=True)
            run_lifecycle_activity(profile, funnel, life)

        for _ in range(n):
            user_id += 1
            user = make_user(user_id, business_hour(day))
            variants = assign_experiments(user)
            funnel = run_onboarding(user, variants)
            life = run_subscription(user, variants, funnel["activated"])
            run_lifecycle_activity(user, funnel, life)
            if life["paid"]:
                started_at, ended_at, _plan = life["paid"]
                if ended_at and rng.random() < 0.09:
                    back_at = ended_at + timedelta(days=rng.randrange(60, 181))
                    if back_at < SNAPSHOT - timedelta(days=TRIAL_DAYS):
                        reactivation_queue.append((back_at, user))
                        reactivation_queue.sort(key=lambda x: x[0])

    make_ad_spend(ad_spend, paid_signups)
    add_dirt(users, events, next_id, new_device)

    return {"users": users, "subscriptions": subs, "subscription_events": sub_events,
            "payments": payments, "events": events, "experiment_assignments": assignments,
            "touchpoints": touchpoints, "ad_spend": ad_spend}


def make_ad_spend(ad_spend, paid_signups):
    """Суточные расходы из рекламных кабинетов.

    Так расход и приходит в хранилище: строка на день, канал и кампанию, без
    всякой связи с конкретным пользователем. Связать его с регистрациями можно
    только по дате и каналу — и вот тут вылезает главная проблема расчёта CAC:
    расход известен точно, а регистрации атрибуцированы неполно.

    Заложены две неприятности, которые есть в любом кабинете:
      • расход идёт и в дни, когда регистраций из канала не было вовсе;
      • он никогда не равен «число регистраций × целевой CAC» — ставки
        плавают, аукцион меняется, часть кликов не доходит до сайта.
    """
    days = (SNAPSHOT.date() - START_DATE).days
    for i in range(days):
        day = START_DATE + timedelta(days=i)
        for code, campaigns in CAMPAIGNS.items():
            channel = CHANNEL_BY_CODE[code]
            signups = paid_signups.get((day, code), 0)
            # базовый расход есть всегда: реклама крутится и в выходные, когда
            # никто не регистрируется
            spend = (signups * channel[4] * rng.gauss(1.0, 0.22)
                     + channel[4] * rng.uniform(0.05, 0.45))
            if spend <= 0:
                continue
            weights = [rng.uniform(0.5, 1.5) for _ in campaigns]
            total_w = sum(weights)
            for campaign, w in zip(campaigns, weights):
                part = spend * w / total_w
                cpc = rng.uniform(18, 62)
                clicks = max(1, int(part / cpc))
                ad_spend.append((ts(datetime(day.year, day.month, day.day))[:10],
                                 channel[0], campaign, f"{part:.2f}",
                                 clicks, clicks * rng.randrange(8, 40)))


# --------------------------------------------------------------------------- #
# Дефекты данных
# --------------------------------------------------------------------------- #

def add_dirt(users, events, next_id, new_device):
    """Добавляет в сырой слой то, что есть в любой реальной выгрузке.

    Три дефекта, все типовые:

      1. Служебные аккаунты сотрудников. Отличаются только доменом почты —
         тем же, что у самой компании. Не выкинешь — занизишь конверсию.

      2. Трафик ботов и поисковых роботов. Устройства, которые ходят по сайту
         и никогда не заводят аккаунт. Склейка их отбрасывает сама: связать
         такое устройство не с кем.

      3. Дубли от ретраев трекера: две строки, разные event_id, один event_uid.

    Функция работает ПОСЛЕ основной генерации на отдельном потоке случайных
    чисел, поэтому ничего в уже созданных данных не сдвигает.
    """
    # ---- служебные аккаунты ---------------------------------------------- #
    base_id = max(u[0] for u in users)
    for i in range(1, INTERNAL_ACCOUNTS + 1):
        uid = base_id + i
        day = START_DATE + timedelta(days=dirt_rng.randrange(40, 560))
        signed_up = datetime(day.year, day.month, day.day,
                             dirt_rng.randrange(9, 20), dirt_rng.randrange(60))
        users.append((uid, ts(signed_up), "RU", "11-50", STAFF_DOMAIN))
        device = new_device()

        script = [("signup", 0.0), ("email_confirmed", 0.2), ("project_created", 1.5)]
        script += [("task_created", 2.0 + j) for j in range(dirt_rng.randrange(0, 6))]
        for name, offset_h in script:
            when = signed_up + timedelta(hours=offset_h)
            if when >= SNAPSHOT:
                continue
            eid = next_id("event")
            events.append((eid, event_uid(eid, uid), device, uid, ts(when),
                           ts(ingest_time(when)), name, "web"))

    # ---- боты ------------------------------------------------------------- #
    for _ in range(BOT_DEVICES):
        device = new_device()
        day = START_DATE + timedelta(days=dirt_rng.randrange(0, 600))
        start_at = datetime(day.year, day.month, day.day, dirt_rng.randrange(24))
        for j in range(dirt_rng.randrange(20, 140)):
            # характерная примета робота: строго равные интервалы между заходами
            when = start_at + timedelta(seconds=60 * j)
            if when >= SNAPSHOT:
                break
            eid = next_id("event")
            events.append((eid, f"bot-{eid:08x}", device, "", ts(when),
                           ts(ingest_time(when)), "page_view", "web"))

    # ---- дубли от ретраев ------------------------------------------------- #
    originals = list(events)
    for _ in range(int(len(originals) * DUPLICATE_SHARE)):
        src = originals[dirt_rng.randrange(len(originals))]
        arrived = datetime.strptime(src[5], "%Y-%m-%d %H:%M:%S")
        retry = min(arrived + timedelta(seconds=dirt_rng.uniform(2, 900)),
                    SNAPSHOT - timedelta(seconds=1))
        events.append((next_id("event"), src[1], src[2], src[3], src[4],
                       ts(retry), src[6], src[7]))


# --------------------------------------------------------------------------- #
# Запись CSV
# --------------------------------------------------------------------------- #

HEADERS = {
    "plans": ["plan_id", "plan_code", "plan_name", "plan_rank", "billing_period",
              "price_rub", "seats_included"],
    "channels": ["channel_id", "channel_code", "channel_name", "channel_group"],
    "users": ["user_id", "signed_up_at", "country_code", "company_size", "email_domain"],
    "touchpoints": ["touchpoint_id", "device_id", "occurred_at", "channel_id",
                    "campaign", "is_direct"],
    "ad_spend": ["spend_date", "channel_id", "campaign", "spend_rub", "clicks", "impressions"],
    "subscriptions": ["subscription_id", "user_id", "plan_id", "trial_started_at", "trial_ended_at",
                      "started_at", "ended_at", "status", "cancel_reason_raw", "seats"],
    "subscription_events": ["event_id", "subscription_id", "occurred_at", "event_type", "plan_id",
                            "mrr_before_rub", "mrr_after_rub"],
    "payments": ["payment_id", "subscription_id", "paid_at", "amount_rub", "status", "attempt_no"],
    "events": ["event_id", "event_uid", "device_id", "user_id", "occurred_at", "ingested_at",
               "event_name", "platform"],
    "experiments": ["experiment_id", "experiment_code", "experiment_name", "hypothesis",
                    "primary_metric", "started_at", "ended_at"],
    "experiment_assignments": ["experiment_id", "user_id", "variant", "assigned_at"],
}


def write_csv(name, rows):
    path = os.path.join(DATA_DIR, f"{name}.csv")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(HEADERS[name])
        writer.writerows(rows)
    return path, len(rows)


def main():
    parser = argparse.ArgumentParser(description="Генерация данных SaaS «Тайм-лайн»")
    parser.add_argument("--users", type=int, default=12000,
                        help="сколько регистраций сгенерировать (по умолчанию 12000)")
    args = parser.parse_args()

    os.makedirs(DATA_DIR, exist_ok=True)
    tables = generate(args.users)

    write_csv("plans", [(p[0], p[1], p[2], p[3], p[4], f"{p[5]:.2f}", p[6]) for p in PLANS])
    write_csv("channels", [(c[0], c[1], c[2], c[3]) for c in CHANNELS])
    write_csv("experiments", [(e[0], e[1], e[2], e[3], e[4], ts(e[5]), ts(e[6])) for e in EXPERIMENTS])

    # порядок важен: справочники и users должны попасть в БД раньше ссылающихся таблиц
    for name in ("users", "touchpoints", "ad_spend", "subscriptions",
                 "subscription_events", "payments", "events", "experiment_assignments"):
        _path, n = write_csv(name, tables[name])
        print(f"  {name:<24} {n:>8,} строк".replace(",", " "))

    print(f"\nCSV записаны в {DATA_DIR}")
    print(f"Дата среза: {SNAPSHOT:%Y-%m-%d}, период: с {START_DATE:%Y-%m-%d}")


if __name__ == "__main__":
    main()
