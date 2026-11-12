"""Bounded display metadata and a model-free projection of the current workflow."""

from dataclasses import dataclass
from pathlib import Path
import time

from cycle_prompts import PROFILES, REVIEW_ROLES, REVIEW_TARGETS, review_target, FINAL_ROLES
from cycle_state import QUOTA_PROBE_PERIOD
from focus_output import terminal_text


PHASES = ("code", *REVIEW_ROLES, "final", "publish", "ci")
NAMES = {"opus_final": "Поздний Opus", "final": "Финальный раунд",
         "final_opus": "Финальный Opus", "final_astra": "Финальный Astra", "final_triage": "Проверка находок Astra",
         "final_fix": "Исправления Opus", "final_cleanup": "Закрытие неблокирующих Opus",
         "pair_fix": "Исправления Opus", "pair_cleanup": "Закрытие неблокирующих Opus",
         "pair_fix_high": "Исправления Opus", "pair_cleanup_high": "Закрытие незначимых Opus",
         "pair_complexity": "Оценка сложности",
         "code": "Реализация", "opus": "Opus", "sol": "Sol", "claude": "Fable", "astra": "Astra",
         "publish": "Публикация", "ci": "CI", "coordinate": "Координация", "heal": "Восстановление"}


def clean(value, limit=200):
    return " ".join(terminal_text(str(value)[:4000]).split())[:limit]


@dataclass(frozen=True)
class StatusPanel:
    lines: tuple
    compact: tuple
    tone: str = "normal"


def accept_task(state, report, role):
    """Task labels never choose a stage or decide whether a report is accepted."""
    if state.get("review_run") or state.get("publication_scope"):
        return  # The operator's sealed selection owns the campaign identity.
    value = report.get("task")
    if role not in ("coordinate", "code") or not isinstance(value, dict):
        return
    if set(value) != {"id", "title", "plan"} or any(
            not isinstance(value[k], str) or not value[k].strip() or len(value[k]) > 1000 for k in value):
        return
    try:
        root = Path(state["root"]).resolve()
        path = (root / value["plan"]).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            return
        task = {"id": clean(value["id"], 80), "title": clean(value["title"], 180),
                "plan": path.relative_to(root).as_posix(), "iteration": state["iteration"]}
    except (OSError, ValueError, RuntimeError):
        return
    previous = (state.get("previous_stage") or {}).get("task") or {}
    old = state.get("task")
    if role == "coordinate" and (previous.get("id"), previous.get("plan")) == (task["id"], task["plan"]):
        if old and old.get("iteration") == state["iteration"] and (old.get("id"), old.get("plan")) == (
                task["id"], task["plan"]) and state.get("task_source") in ("code", "operator"):
            return None  # A code report already continues this stage.
        # The plan can still show the published stage as open. Only a code report can continue that stage.
        return "previous-stage"
    if old and old.get("iteration") == state["iteration"] and (
            old.get("id"), old.get("plan")) != (task["id"], task["plan"]):
        if role != "code" or state.get("code_report") or state.get("task_source") in ("code", "operator"):
            return  # Only the first accepted code report can replace a provisional coordinator label.
    if task["id"] and task["title"]:
        state["task"] = task
        if role == "code" or state.get("task_source") not in ("code", "operator"):
            state["task_source"] = role


def new_reviews():
    return {role: {"completed": 0, "history_known": True} for role in REVIEW_ROLES}


def review_info(state, role):
    saved = (state.get("display_reviews") or {}).get(role)
    if saved is not None:
        return dict(saved)
    # Old state knows the Sol round and clean streaks, not lifetime pass totals.
    return {"completed": state.get("sol_passes", 0) if role == "sol" else state.get(role + "_clean", 0),
            "history_known": False}


def review_event(state, role, outcome, reason="", completed=False):
    entry = review_info(state, role)
    if completed:
        entry["completed"] += 1
    entry.update(outcome=outcome, reason=clean(reason, 160), at=time.time())
    state.setdefault("display_reviews", {})[role] = entry
    event = dict(entry, role=role)
    history = state.setdefault("display_review_events", [])
    history.append(event)
    del history[:-12]


def reset_notice(state, reason, roles=REVIEW_ROLES):
    for role in roles:
        info = review_info(state, role)
        if info["completed"] or state.get(role + "_clean") or (state.get("pending") or {}).get("role") == role:
            review_event(state, role, "сброс серии", reason)


def duration(seconds):
    seconds = max(0, int(seconds or 0))
    return f"{seconds // 3600}:{seconds // 60 % 60:02}:{seconds % 60:02}" if seconds >= 3600 else f"{seconds // 60:02}:{seconds % 60:02}"


def activity_text(value):
    value = clean(value, 160)
    labels = {"command running": "Команда выполняется", "command completed": "Команда завершена",
              "file edit running": "Изменение файлов", "file edit completed": "Файлы изменены",
              "model processing": "Модель обрабатывает задачу", "response running": "Модель пишет ответ",
              "response completed": "Ответ получен", "composing response": "Модель пишет ответ",
              "preparing tool call": "Подготовка команды", "tool result received": "Получен результат инструмента",
              "session ready": "Сессия готова", "starting provider / restoring session": "Запуск / продолжение сессии",
              "provider finished; validating result": "Проверка отчёта",
              "response received; checking completion": "Ответ получен; проверка завершения",
              "tool running:": "Работает инструмент:"}
    for prefix, label in labels.items():
        if value.startswith(prefix):
            return label + (value[len(prefix):] if prefix in ("tool running:", "command completed") else "")
    return value or "Подготовка следующего действия"


def build_panel(state, live=None, paused=False, approval=False, notice="", stop="", finish_stage=None):
    """Pure, bounded formatting: no disk, Git, provider calls or transcript scans."""
    if state.get("review_profile", 0) >= 6 and not state.get("publication_review_profile") and state.get("phase") not in REVIEW_ROLES and not state.get("final_review"):
        return pair_panel(state, live, paused, approval, notice, stop, finish_stage)
    live = live or {}
    phase = state.get("phase", "code")
    legacy_publication = state.get("publication_review_profile") in (1, 2, 3, 4, 5, 6, 7) and phase in ("publish", "ci")
    index = PHASES.index(phase) if phase in PHASES else 0
    task = state.get("task") or {}
    if task.get("iteration") != state.get("iteration"):
        task = {}
    project = Path(state.get("root", ".")).name
    previous = (state.get("previous_stage") or {}).get("task") or {}
    # Until a report names the stage, the published stage tells where the iteration stands.
    fallback = f"Задача {state.get('iteration', 1)}" + (f" · после {previous['id']}" if previous.get("id") else "")
    title = f"{project} · " + (f"{task['id']} · {task['title']}" if task else fallback)
    blocker = state.get("blocker") or {}
    complete = state.get("status") == "complete"
    blocked = blocker.get("status") == "blocked"
    quota = (state.get("pending") or {}).get("quota_wait")
    transient = (state.get("pending") or {}).get("transient_wait")
    active_role = live.get("role") if live.get("active") and not paused and not quota and not transient else None
    mode, tone = ("В РАБОТЕ", "normal")
    if complete:
        mode, tone = "ПЛАН ЗАВЕРШЁН", "good"
    elif blocked:
        mode, tone = "БЛОКИРОВКА", "error"
    elif approval:
        mode, tone = "НУЖНО СОГЛАСИЕ", "warning"
    elif stop:
        mode, tone = "ОСТАНОВКА" if stop == "now" else "ОЖИДАНИЕ ПАУЗЫ", "warning"
    elif paused:
        mode, tone = ("ЭТАП ЗАВЕРШЁН · ПАУЗА" if state.get("stage_completed") else
                      "ПРЕРВАНО" if state.get("status") == "interrupted" else "ПАУЗА"), "warning"
    elif quota:
        mode, tone = "ОЖИДАНИЕ КВОТЫ", "warning"
    elif transient:
        mode, tone = "ОЖИДАНИЕ ПОВТОРА", "warning"
    elif active_role == "heal" or blocker.get("status") == "healing":
        mode, tone = "ВОССТАНОВЛЕНИЕ", "warning"
    role_label = NAMES.get(active_role or phase, phase)
    if active_role in REVIEW_ROLES:
        role_label = "Ревью " + role_label
    elif active_role == "coordinate":
        role_label += " → " + NAMES.get(phase, phase)
    elif active_role == "heal":
        role_label = NAMES.get(phase, phase)
    elif active_role == "code" and (state.get("pending") or {}).get("resume_code"):
        role_label += " (продолжение)"
    profile = ""
    if active_role in PROFILES:
        _, model, effort = PROFILES[active_role]
        model = {"claude-fable-5-2": "Fable 5.2", "opus": "Opus", "gpt-6.1-sol": "Sol 6.1",
                 "gpt-6-astra": "Astra", "gpt-5.6-luna": "Luna"}.get(model, model)
        profile = f" · {effort}" if active_role in (*REVIEW_ROLES, *FINAL_ROLES) else f" · {model}/{effort}"
    remaining = len(PHASES) - index - 1
    route = state.get("review_plan") or []
    following = route[1:]
    if phase in REVIEW_ROLES and route:
        if state.get("review_substantial") and phase != "opus":
            added = ([{"role": "astra"}] if phase == "opus_final" else [{"role": "opus"}])
            following = added + following
        remaining = len(following) + 3  # Final inspection round, publication and CI.
    position = f"шаг {index + 1}/{len(PHASES)} · этапов впереди: {remaining}" if not complete else "незавершённых задач нет"
    headline = f"{mode} · {role_label}{profile} · {position}"
    if finish_stage:
        headline += " · пауза после этапа и CI"
    if route and route[0].get("repeat_for"):
        headline += " · повтор после " + NAMES.get(route[0]["repeat_for"], route[0]["repeat_for"])
    if phase in REVIEW_ROLES and following:
        headline += " · далее: " + " → ".join(NAMES[v["role"]] for v in following)
    ci = state.get("display_ci") or {}
    if phase != "ci" or ci.get("sha") != (state.get("published") or {}).get("sha"):
        ci = {}
    timeline = []
    for n, name in enumerate(PHASES):
        marker = "✓" if n < index else ("!" if blocked else "▶") if n == index else "○"
        label = NAMES[name]
        if name in REVIEW_ROLES and name != phase:
            marker = "✓" if state.get(name + "_clean", 0) >= review_target(state, name) else "○"
        if legacy_publication and name in (*REVIEW_ROLES, "final"):
            marker = "—"
        if name == "ci" and ci.get("status") == "not-configured":
            marker, label = "—", "CI не требуется"
        elif name == "ci" and ci.get("status") == "ready":
            marker = "✓"
        timeline.append(f"{marker} {label}")
    timeline = " ─ ".join(timeline) if not complete else "✓ Источник задач исчерпан"
    reviews = []
    for role in REVIEW_ROLES:
        target = review_target(state, role)
        info = review_info(state, role)
        streak = state.get(role + "_clean", 0)
        total = info["completed"]
        ordinal = str(total + 1) if info["history_known"] else ""
        if active_role == role:
            detail = f"проход{' ' + ordinal if ordinal else ''} выполняется · серия {streak}/{target} · нужно ≥{max(0, target - streak)}"
            if not info["history_known"]:
                detail += f" · завершено ≥{total}"
        elif streak >= target:
            detail = f"✓ зачтено {streak}/{target}"
        elif info.get("outcome"):
            detail = f"{info['outcome']} · серия {streak}/{target}"
            if info.get("reason"):
                detail += " · " + info["reason"]
        elif total:
            detail = f"ожидает продолжения · серия {streak}/{target}"
        else:
            detail = f"впереди · нужно {target} чистых подряд"
        if not (active_role == role):
            detail += f" · завершено {'≥' if not info['history_known'] else ''}{total}"
        reviews.append(f"{NAMES[role]}: {detail}")
    final = state.get("final_review") or {}
    if phase == "final":
        step = final.get("step", "final_opus")
        blockers = (str(sum(bool(r.get('blocking')) for r in final['confirmed']))
                    if 'confirmed' in final else "оценка впереди")
        detail = (f"раунд {final.get('round', 1)} · {NAMES.get(step, step)} · "
                  f"ревью завершено {len(final.get('scans', []))}/3 · "
                  f"находок: {sum(r.get('findings', 0) for r in final.get('scans', []))} · "
                  f"блокирующих: {blockers}")
        if step == "final_cleanup":
            detail += f" · закрыть: {len(final.get('confirmed', []))} · далее публикация без повторного ревью"
        reviews.append("Финал: " + detail)
    elif final.get("step") == "done":
        closing = (f"закрыто Opus: {len(final.get('confirmed', []))}" if final.get("cleanup")
                   else f"в бэклоге {len(final.get('confirmed', []))}")
        reviews.append(f"Финал: ✓ раунд {final['round']} без блокирующих · {closing}")
    if legacy_publication:
        reviews = ["Публикация по прежнему ревью; новый профиль — со следующей стадии"]
    activity = activity_text(live.get("activity", ""))
    if live.get("operation") == "git":
        activity = "Проверка Git remote · модель не запущена"
    elif phase == "ci" and not active_role:
        activity = "CI: " + ({"not-configured": "не требуется", "ready": "проверки прошли"}.get(ci.get("status"),
                              f"успешно {ci.get('passed', 0)}/{ci.get('total', '?')} · ожидание проверок"))
    if live and not paused:
        activity += f" · вызов {duration(live.get('elapsed_seconds'))} · событие {int(live.get('event_age_seconds', 0))} с назад"
    if blocked:
        activity = clean(blocker.get("resolution") or blocker.get("message") or blocker.get("code"), 180) + " · /resume после устранения"
    elif approval:
        activity = "/approval — операция · /approve или /deny · /log — журнал"
    elif stop:
        activity = "Ожидаем завершения процессов" if stop == "now" else "Пауза после текущего шага; публикация включает CI"
    elif notice:
        activity = notice
    elif paused:
        activity = ("/resume — начать следующий этап · /exit — закрыть" if state.get("stage_completed") else
                    "/resume — продолжить · /messages — сообщения · /exit — закрыть")
    elif quota:
        retry = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(quota["retry_at"]))
        login = "смена логина — повтор сразу" if quota.get("account") else "после смены логина — /resume"
        activity = (f"Claude · повтор {retry} · через {duration(quota['retry_at'] - time.time())} · автоматически · {login} · "
                    f"проверка квоты каждые {QUOTA_PROBE_PERIOD // 60} мин · модель не запущена")
    elif transient:
        activity = (f"{transient.get('provider', 'Claude')} · серверная ошибка · повтор {transient['attempt']}/{transient['limit']} "
                    f"через {duration(transient['retry_at'] - time.time())} · автоматически · модель не запущена")
    lines = tuple(clean(line, 400) for line in (title, headline, timeline, *reviews, activity))
    counts = " · ".join(f"{NAMES[role]} {state.get(role + '_clean', 0)}/{review_target(state, role)}" for role in REVIEW_ROLES)
    compact_progress = f"{role_label} · {index + 1}/{len(PHASES)} · {counts}" if not complete else position
    if legacy_publication:
        compact_progress = f"{role_label} · прежний профиль ревью"
    if finish_stage:
        compact_progress += " · пауза после этапа и CI"
    compact = (clean(f"{mode} · {title}", 400), clean(compact_progress, 400), lines[-1])
    return StatusPanel(lines, compact, tone)


def pair_panel(state, live=None, paused=False, approval=False, notice="", stop="", finish_stage=None):
    from focus_pair_profile import PAIRS
    phases = ("code", "pair_a", "pair_b", "final", "publish", "ci")
    review_run = state.get("review_run")
    if review_run:
        phases = phases[1:]
    labels = {"code": "Реализация", "pair_a": "Пара A", "pair_b": "Пара B",
              "final": "Финальная пара", "publish": "Публикация", "ci": "CI"}
    phase = state.get("phase", "code")
    index = phases.index(phase) if phase in phases else 0
    pair = state.get("pair_review") or {}
    repair = pair.get("repair") or {}
    readers = repair.get("evidence_reader") or repair.get("reader") or pair
    legacy = build_panel(dict(state, review_profile=5), live, paused, approval, notice, stop, finish_stage)
    title, old_headline = legacy.lines[:2]
    if review_run:
        title = "ПОВТОРНОЕ РЕВЬЮ · " + title
        title += f" · целей закрыто: {len(review_run['results'])}/{review_run['target_count']}"
    if state.get("status") == "complete":
        if review_run:
            return StatusPanel((title, "✓ Выбранные цели проверены · публикация и CI завершены"), (title,), "good")
        return StatusPanel((title, old_headline, legacy.lines[-1]), legacy.compact, legacy.tone)
    blocker = state.get("blocker") or {}
    blocked = blocker.get("status") == "blocked"
    tone = legacy.tone
    headline = old_headline.split(" · шаг ")[0]
    if phase in PAIRS:
        headline = headline.replace("Финальный раунд", labels[phase])
        if phase != "final":
            headline = headline.replace(phase, labels[phase])
    headline += f" · шаг {index + 1}/{len(phases)} · этапов впереди: {len(phases) - index - 1}"
    if finish_stage:
        headline += " · пауза после этапа и CI"
    active_keys = (state.get("pending") or {}).get("participants", {})
    active_jobs = [readers.get("jobs", {}).get(key, {}) for key in active_keys]
    waiting = [j for j in active_jobs if j.get("status") == "waiting"]
    if waiting and not any(j.get("status") == "running" for j in active_jobs) and not (blocked or approval or stop or paused):
        headline = "ОЖИДАНИЕ ПОВТОРА · " + headline.split(" · ", 1)[-1]
        tone = "warning"
    if state.get("pair_return"):
        headline += " · повтор A после существенных правок B"
    timeline = " ─ ".join(("✓ " if i < index else "! " if i == index and blocked else "▶ " if i == index else "○ ") + labels[p]
                           for i, p in enumerate(phases))
    counts = state.get("pair_clean", {})
    summary = f"A: {counts.get('pair_a', 0)}/2 чистых · B: {counts.get('pair_b', 0)}/2 чистых · финал: 1 раунд без блокеров"
    if state.get("review_profile", 0) >= 7:
        completed = state.get("pair_completed", {})
        summary = " · ".join(f"{label}: {'✓ завершён' if key in completed else 'до устранения значимых'}"
                             for key, label in (("pair_a", "A"), ("pair_b", "B"), ("final", "Финал")))
    rows = [title, headline, timeline, summary]
    if pair:
        effort = PROFILES.get(pair.get("executor_role"), (None, None, "xhigh"))[2]
        assessor = PROFILES["pair_complexity"][1]
        steps = {"scan": "независимое чтение", "discuss": "согласование", "arbitrate": "арбитраж Astra/max",
                 "complexity": f"оценка сложности {assessor}/high", "decide": "проверка решений",
                 "fix": f"исправления Opus/{effort}", "cleanup": f"закрытие незначимых Opus/{effort}"}
        if repair.get("final_gate") and repair["step"] in ("test", "evidence", "complete") and not repair.get("reviews"):
            step = {"test": "полный прогон Opus/xhigh", "evidence": "проверка журнальной записи", "complete": "прогон завершён"}.get(repair["step"], repair["step"])
            rows.append(f"Финальный гейт · {step}")
            rows.append("Запрос финальной пары: полный прогон перед публикацией · далее: публикация")
        elif repair:
            mode = "самопроверка Opus/xhigh" if repair["mode"] == "self" else "Opus/xhigh + Astra/xhigh"
            step = {"fix": "исправление", "review": "статическое ревью", "test": "целевые тесты", "evidence": "проверка журнальной записи", "complete": "проверка завершена"}.get(repair["step"], repair["step"])
            destination = "повтор внешней пары" if repair["repeat_outer"] else "следующий этап"
            rows.append(f"Проверка исправлений · {mode} · {repair['clean']}/2 чистых · {step}")
            rows.append(f"Выбор: {repair['reason']} · далее: {destination}")
        else:
            rows.append(f"Раунд {pair['round']} · {steps.get(pair['step'], pair['step'])} · обмен {pair.get('discussion', 0)}/2 · находок {len(pair.get('issues', []))}")
            if pair.get("execution"):
                execution = pair["execution"]
                rows.append(f"Исполнитель: закрыто {len(execution['resolutions'])}/{len(pair['tasks'])} · осталось {len(execution['remaining'])} заданий")
        for role in (readers.get("roles", ()) if repair else PAIRS.get(phase, ())):
            candidates = [j for j in list(readers.get("jobs", {}).values()) if j["role"] in (role, role + "_discuss")]
            job = max(candidates, key=lambda j: j.get("created", 0)) if candidates else {}
            _, model, effort = PROFILES[role]
            detail = {"done": "отчёт сохранён", "running": "работает", "waiting": "ждёт квоту/повтор", "interrupted": "прерван"}.get(job.get("status"), "впереди")
            if job.get("retry_at") and job.get("status") == "waiting":
                detail += " · через " + duration(job["retry_at"] - time.time())
            activity = (job.get("live") or {}).get("activity", "")
            rows.append(f"{model}/{effort}: {detail}" + (" · " + activity_text(activity) if activity else ""))
    activity = legacy.lines[-1]
    ci = state.get("display_ci") or {}
    if phase == "ci" and ci.get("sha") == (state.get("published") or {}).get("sha"):
        if ci.get("status") == "not-configured":
            rows[2] = rows[2].replace("▶ CI", "— CI не требуется")
        elif ci.get("status") == "ready":
            rows[2] = rows[2].replace("▶ CI", "✓ CI")
    if pair.get("step") == "cleanup":
        if pair.get("execution", {}).get("substantial"):
            destination = "повтор этой пары"
        else:
            destination = ("публикация" if phase == "final" else "следующая пара") + " без повторного ревью"
        rows[4] += f" · закрыть: {len(pair.get('tasks', []))} · далее {destination}"
    rows.append(activity)
    return StatusPanel(tuple(clean(row, 400) for row in rows), (clean(headline), clean(summary), clean(activity)), tone)
