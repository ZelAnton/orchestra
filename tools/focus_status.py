"""Bounded display metadata and a model-free projection of the current workflow."""

from dataclasses import dataclass
from pathlib import Path
import time

from cycle_prompts import PROFILES, REVIEW_ROLES, REVIEW_TARGETS
from focus_output import terminal_text


PHASES = ("code", "sol", "claude", "astra", "publish", "ci")
NAMES = {"code": "Реализация", "sol": "Sol", "claude": "Opus", "astra": "Astra",
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
    old = state.get("task")
    if old and old.get("iteration") == state["iteration"] and (
            old.get("id"), old.get("plan")) != (task["id"], task["plan"]):
        return  # A later transition cannot relabel this iteration as another task.
    if task["id"] and task["title"]:
        state["task"] = task


def new_reviews():
    return {role: {"completed": 0, "history_known": True} for role in ("sol", "claude", "astra")}


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


def reset_notice(state, reason, roles=("sol", "claude", "astra")):
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


def build_panel(state, live=None, paused=False, approval=False, notice="", stop=""):
    """Pure, bounded formatting: no disk, Git, provider calls or transcript scans."""
    live = live or {}
    phase = state.get("phase", "code")
    legacy_publication = state.get("publication_review_profile") == 1 and phase in ("publish", "ci")
    index = PHASES.index(phase) if phase in PHASES else 0
    task = state.get("task") or {}
    if task.get("iteration") != state.get("iteration"):
        task = {}
    project = Path(state.get("root", ".")).name
    title = f"{project} · " + (f"{task['id']} · {task['title']}" if task else f"Задача {state.get('iteration', 1)}")
    blocker = state.get("blocker") or {}
    complete = state.get("status") == "complete"
    blocked = blocker.get("status") == "blocked"
    quota = (state.get("pending") or {}).get("quota_wait")
    active_role = live.get("role") if live.get("active") and not paused and not quota else None
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
        mode, tone = "ПРЕРВАНО" if state.get("status") == "interrupted" else "ПАУЗА", "warning"
    elif quota:
        mode, tone = "ОЖИДАНИЕ КВОТЫ", "warning"
    elif active_role == "heal" or blocker.get("status") == "healing":
        mode, tone = "ВОССТАНОВЛЕНИЕ", "warning"
    role_label = NAMES.get(active_role or phase, phase)
    if active_role in ("sol", "claude", "astra"):
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
        model = {"claude-fable-5-1": "Fable 5.1", "opus": "Opus", "gpt-6-sol": "Sol",
                 "gpt-6-astra": "Astra", "gpt-5.6-luna": "Luna"}.get(model, model)
        profile = f" · {effort}" if active_role in REVIEW_ROLES else f" · {model}/{effort}"
    remaining = len(PHASES) - index - 1
    position = f"шаг {index + 1}/{len(PHASES)} · этапов впереди: {remaining}" if not complete else "незавершённых задач нет"
    headline = f"{mode} · {role_label}{profile} · {position}"
    ci = state.get("display_ci") or {}
    if phase != "ci" or ci.get("sha") != (state.get("published") or {}).get("sha"):
        ci = {}
    timeline = []
    for n, name in enumerate(PHASES):
        marker = "✓" if n < index else ("!" if blocked else "▶") if n == index else "○"
        label = NAMES[name]
        if legacy_publication and name in REVIEW_ROLES:
            marker = "—"
        if name == "ci" and ci.get("status") == "not-configured":
            marker, label = "—", "CI не требуется"
        elif name == "ci" and ci.get("status") == "ready":
            marker = "✓"
        timeline.append(f"{marker} {label}")
    timeline = " ─ ".join(timeline) if not complete else "✓ Источник задач исчерпан"
    reviews = []
    for role, target in REVIEW_TARGETS.items():
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
        activity = "Проверьте операцию в логе · /approve или /deny"
    elif stop:
        activity = "Ожидаем завершения процессов" if stop == "now" else "Пауза после текущего шага; публикация включает CI"
    elif notice:
        activity = notice
    elif paused:
        activity = "/resume — продолжить · /messages — сообщения · /exit — закрыть"
    elif quota:
        retry = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(quota["retry_at"]))
        activity = f"Claude · повтор {retry} · через {duration(quota['retry_at'] - time.time())} · автоматически · модель не запущена"
    lines = tuple(clean(line, 400) for line in (title, headline, timeline, *reviews, activity))
    compact_progress = (f"{role_label} · {index + 1}/{len(PHASES)} · Sol {state.get('sol_clean', 0)}/3"
                        f" · Opus {state.get('claude_clean', 0)}/2 · Astra {state.get('astra_clean', 0)}/1") if not complete else position
    if legacy_publication:
        compact_progress = f"{role_label} · прежний профиль ревью"
    compact = (clean(f"{mode} · {title}", 400), clean(compact_progress, 400), lines[-1])
    return StatusPanel(lines, compact, tone)
