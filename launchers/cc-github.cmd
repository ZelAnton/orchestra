@echo off
chcp 65001 >nul
rem Запуск github_sync в текущей папке (Claude Code, auto-режим). Требует gh CLI с авторизацией.
rem Заводит задачи из открытых issues/PR и закрывает готовые (PR — всегда close, не merge).
rem Без предопределённого промпта: агент запускается и ждёт указания задачи в чате.
claude --agent github_sync --permission-mode auto
