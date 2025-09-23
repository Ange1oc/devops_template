#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Интерактивный помощник для Git:
# 1) Переключить origin на OneDev (по желанию).
#    Дополнительно можно переименовать старый origin -> github.
# 2) Изменить ТОЛЬКО локальный user.email (и при желании user.name).
# -------------------------------

say() { printf "%s\n" "$*"; }
hr()  { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'; }

ask_yn() {
  # Использует y/n/yes/no/д/да/н/нет
  local q="$1"
  local ans
  while true; do
    read -rp "$q [y/n]: " ans || true
    case "${ans,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) say "Пожалуйста, введите y или n."; ;;
    esac
  done
}

ensure_git_repo() {
  if ! command -v git >/dev/null 2>&1; then
    say "git не установлен. Установите git и повторите попытку."; exit 1
  fi
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    say "Похоже, вы НЕ в каталоге Git-репозитория. Перейдите в нужный проект и запустите скрипт снова."
    exit 1
  fi
}

change_remote() {
  hr
  say "Текущие remotes:"
  git remote -v || true
  hr

  if ask_yn "Изменить удалённый репозиторий (origin) на новый?"; then
    local new_url=""
    while [[ -z "${new_url}" ]]; do
      read -rp "Введите новый URL (например: onedev:/SBContentAdmin): " new_url || true
      [[ -z "${new_url}" ]] && say "URL не может быть пустым."
    done

    if git remote get-url origin >/dev/null 2>&1; then
      # origin существует
      if ask_yn "Переименовать текущий 'origin' в 'github' и ДОБАВИТЬ новый 'origin' (${new_url})? (иначе просто заменим URL у origin)"; then
        if git remote | grep -qx "github"; then
          say "Remote 'github' уже существует — переименование пропущено."
          say "Обновляю URL origin -> ${new_url}"
          git remote set-url origin "${new_url}"
        else
          say "Переименовываю origin -> github..."
          git remote rename origin github
          say "Добавляю новый origin -> ${new_url}"
          git remote add origin "${new_url}"
        fi
      else
        say "Обновляю URL origin -> ${new_url}"
        git remote set-url origin "${new_url}"
      fi
    else
      # origin отсутствует
      say "Remote 'origin' не найден. Добавляю origin -> ${new_url}"
      git remote add origin "${new_url}"
    fi

    hr
    say "Готово. Актуальные remotes:"
    git remote -v
    hr
  else
    say "Шаг изменения remote пропущен."
  fi
}

change_local_email() {
  hr
  if ask_yn "Изменить e-mail ТОЛЬКО для ЭТОГО репозитория (локально)?"; then
    local current_email current_name
    current_email="$(git config --local --get user.email || true)"
    current_name="$(git config --local --get user.name || true)"

    say "Текущий локальный e-mail: ${current_email:-<не задан>}"
    local new_email=""
    while [[ -z "${new_email}" ]]; do
      read -rp "Введите новый e-mail: " new_email || true
      [[ -z "${new_email}" ]] && say "e-mail не может быть пустым."
    done
    git config --local user.email "${new_email}"
    say "Локальный e-mail обновлён."

    if ask_yn "Также изменить локальный user.name?"; then
      say "Текущее имя: ${current_name:-<не задано>}"
      local new_name=""
      while [[ -z "${new_name}" ]]; do
        read -rp "Введите новое имя (user.name): " new_name || true
        [[ -z "${new_name}" ]] && say "Имя не может быть пустым."
      done
      git config --local user.name "${new_name}"
      say "Локальный user.name обновлён."
    fi

    hr
    say "Текущие локальные настройки пользователя:"
    git config --local --list | grep -E '^user\.(email|name)=' || true
    hr
  else
    say "Шаг изменения локального e-mail пропущен."
  fi
}

main() {
  ensure_git_repo
  say "=== Git помощник для миграции на OneDev ==="
  change_remote
  change_local_email
  say "Готово."
}

main "$@"
