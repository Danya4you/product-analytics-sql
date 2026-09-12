# Модель данных

Два слоя. **`app`** — сырые данные, как их отдала бы продакшн-база и трекер
событий. **`marts`** — витрины, на которые смотрит аналитик. Аналитические
запросы обращаются только к `marts`; каждое обращение к `app` из запроса —
повод спросить, почему нужного поля нет в витрине.

## Схема `app`

```mermaid
erDiagram
    channels    ||--o{ users              : "привёл"
    users       ||--o{ subscriptions      : "оформил"
    users       ||--o{ events             : "совершил"
    users       ||--o{ experiment_assignments : "попал в"
    plans       ||--o{ subscriptions      : "тариф"
    plans       ||--o{ subscription_events : "тариф после события"
    subscriptions ||--o{ subscription_events : "история"
    subscriptions ||--o{ payments         : "списания"
    experiments ||--o{ experiment_assignments : "распределение"

    channels {
        smallint channel_id PK
        text     channel_code
        text     channel_group
        numeric  cac_rub
    }
    users {
        integer   user_id PK
        timestamp signed_up_at
        smallint  channel_id FK
        text      company_size
        boolean   is_b2b
    }
    plans {
        smallint plan_id PK
        text     plan_code
        smallint plan_rank
        text     billing_period
        numeric  price_rub
    }
    subscriptions {
        integer   subscription_id PK
        integer   user_id FK
        smallint  plan_id FK
        timestamp trial_started_at
        timestamp started_at
        timestamp ended_at
        text      status
        text      cancel_reason
    }
    subscription_events {
        bigint    event_id PK
        integer   subscription_id FK
        timestamp occurred_at
        text      event_type
        numeric   mrr_before_rub
        numeric   mrr_after_rub
    }
    payments {
        bigint    payment_id PK
        integer   subscription_id FK
        timestamp paid_at
        numeric   amount_rub
        text      status
        smallint  attempt_no
    }
    events {
        bigint    event_id PK
        text      event_uid
        integer   user_id FK
        timestamp occurred_at
        timestamp ingested_at
        text      event_name
        text      platform
    }
    experiments {
        smallint  experiment_id PK
        text      experiment_code
        text      primary_metric
    }
    experiment_assignments {
        smallint experiment_id PK
        integer  user_id PK
        text     variant
    }
```

### Зерно таблиц

| Таблица | Одна строка — это | Объём |
|---|---|---|
| `users` | зарегистрированный пользователь | ~12 000 |
| `subscriptions` | подписка, включая не дожившие до оплаты триалы | ~12 000 |
| `subscription_events` | изменение состояния подписки | ~25 000 |
| `payments` | попытка списания (успешная, неуспешная или возврат) | ~12 000 |
| `events` | доставленная запись о действии (с дублями) | ~440 000 |
| `experiment_assignments` | попадание пользователя в вариант эксперимента | ~3 200 |

### Три дефекта, которые есть в выгрузке

Сырой слой намеренно грязный — ровно так, как приходят данные в жизни. Разбор
в `marts.stg_events`, измерение масштаба — в `sql/analysis/00_data_hygiene.sql`.

**Дубли от ретраев.** Клиент не дождался подтверждения и отправил событие
повторно: две строки, разные `event_id`, одинаковый `event_uid`. Около 1,8 %
лога. Дедупликация идёт по `event_uid` — это идемпотентный ключ, присвоенный
клиентом. Сравнение строк целиком такие дубли не поймает: `ingested_at` у
копий разное.

**Служебные аккаунты.** Сорок учёток сотрудников с каналом `internal`. По
поведению неотличимы от клиентов, но не платят никогда. Исключаются в
`stg_events` и `dim_user`.

**Задержка доставки.** `ingested_at` отличается от `occurred_at` на секунды у
91 % событий, но примерно у 1 % — на сутки и больше. Из-за этого отчёт за
период, построенный сразу после его окончания, и он же спустя неделю дают
разные числа. Колонка нужна, чтобы это можно было объяснить, а не гадать.

### Три места, где легко ошибиться

**`subscriptions.plan_id` — текущий тариф, а не тариф на момент оплаты.**
Считать по нему выручку прошлых месяцев нельзя: апгрейд перепишет историю
задним числом. Тариф на момент конверсии берётся из `subscription_events`.

**MRR нормирован к месяцу.** У годовой подписки в `mrr_after_rub` лежит
двенадцатая часть годовой цены, иначе помесячная динамика прыгала бы на порядок
в месяцы годовых списаний. Фактическое списание — в `payments.amount_rub`, и
оно отличается от MRR в двенадцать раз.

**У одного пользователя может быть несколько подписок.** Примерно 9 % ушедших
возвращаются позже. Поэтому `count(*) FROM subscriptions` больше, чем число
пользователей, а в водопаде MRR вторая подписка попадает в `reactivation`, а не
в `new`.

## Схема `marts`

| Витрина | Зерно | Зачем |
|---|---|---|
| `meta` | одна строка | момент выгрузки данных |
| `stg_events` | событие | чистый лог: дубли схлопнуты, служебные аккаунты убраны |
| `dim_date` | день | календарь без пропусков |
| `dim_user` | пользователь | когорта, канал, воронка, флаги активации и конверсии |
| `fct_subscription` | подписка | срок жизни, первый и текущий MRR, собранная выручка |
| `fct_mrr_movement` | изменение MRR | водопад: new / reactivation / expansion / contraction / churn |
| `fct_subscription_month` | подписка × месяц | MRR на конец месяца, для когортного NRR |
| `fct_user_activity_daily` | пользователь × день | свёрнутый лог событий |
| `fct_user_activity_week` | пользователь × неделя жизни | кривые удержания |

Порядок сборки задан именами файлов: `00_schema` → `02_stg_events` →
`05_stats` → `10_dim_user` → … Витрины выше по течению читают `stg_events`, а
не `app.events`: чистка выполняется один раз, и ни один отчёт не может её
случайно пропустить.

Все витрины материализованы. На таком объёме обычные представления работали бы
не сильно медленнее, но материализация фиксирует результат: два запроса в одном
отчёте гарантированно видят одни и те же числа.

### `marts.snapshot_ts()` и почему не `now()`

Дата среза выводится из данных (`max(occurred_at)` в `app.events`), а не из
текущего времени. Иначе одни и те же запросы завтра дадут другие числа, и
проверить кейс станет невозможно.

Функция читает материализованную витрину `marts.meta` из одной строки, а не
считает максимум сама. Причина в том, как PostgreSQL выполняет `STABLE`-функции:
в списке выборки такая функция вычисляется на **каждой строке**. Версия, которая
честно считала `max(occurred_at)` внутри себя, превращала построение `dim_user`
в 12 тысяч полных проходов по 440 тысячам событий — запрос не завершался.

Разница измерена: **10 155 мс против 2,8 мс** на выборке из 200 пользователей,
то есть в 3 700 раз. Планы и методика — в [performance.md](performance.md).

### Определения, заданные в одном месте

Активация задана в `marts.dim_user.is_activated` и нигде больше не повторяется:

```sql
(first_project_at IS NOT NULL AND tasks_first_7d >= 3)
```

Зрелость наблюдения — в `marts.dim_user.is_matured`: зарегистрировался раньше
чем за 30 дней до среза, то есть успел пройти четырнадцатидневный триал и
принять решение. Все запросы, считающие конверсию, фильтруют по этому полю.
Без него конверсия последних недель занижена механически: люди ещё внутри
триала, а в знаменатель уже попали.
