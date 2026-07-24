
prune_handoffs() { # prune_handoffs <handoff-dir> → prints count removed
  local dir="$1" kept=0 removed=0 f date
  [ -d "$dir" ] || { printf '0'; return 0; }
  while IFS=$'\t' read -r date f; do
    [ -n "$f" ] || continue
    kept=$((kept + 1))
    if [ "$kept" -gt "$HANDOFF_RETENTION" ]; then
      rm -f -- "$f"
      removed=$((removed + 1))
    fi
  done < <(
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      date="$(sed -n '1s/.*date=\([^ ]*\).*/\1/p' "$f")"
      printf '%s\t%s\n' "$date" "$f"
    done | sort -r
  )
  printf '%s' "$removed"
}

prune_all_handoffs() {
  sync_ready || return 0
  local dir removed total=0
  for dir in "$SYNC_DIR"/projects/*/handoffs "$SYNC_DIR"/machines/*/handoffs; do
    [ -d "$dir" ] || continue
    removed="$(prune_handoffs "$dir")"
    total=$((total + removed))
  done
  [ "$total" -eq 0 ] || info "pruned $total old handoff(s); keeping the latest $HANDOFF_RETENTION per project or machine"
}

file_handoff() { # file_handoff <project-id-or-empty> <date> <body> — empty id = machine scope
  local id="$1" now="$2" body="$3" out pruned
  if [ -n "$id" ]; then out="$SYNC_DIR/projects/$id/handoffs/${now//:/-}--$MACHINE.md"
  else out="$SYNC_DIR/machines/$MACHINE/handoffs/${now//:/-}.md"; fi
  mkdir -p "$(dirname "$out")"
  {
    printf '%s project=%s machine=%s date=%s -->\n' "$HANDOFF_MARK" "${id:--}" "$MACHINE" "$now"
    printf '%s\n' "$body"
  } > "$out"
  pruned="$(prune_handoffs "$(dirname "$out")")"
  info "handoff saved: ${out#"$SYNC_DIR"/}"
  [ "$pruned" -eq 0 ] || info "pruned $pruned older handoff(s); keeping the latest $HANDOFF_RETENTION"
}

handoff_body_complete() {
  local body="$1" heading
  for heading in '## Goal' '## Done' '## In flight' '## Next steps' '## Gotchas'; do
    case $'\n'"$body"$'\n' in
      *$'\n'"$heading"$'\n'*) ;;
      *) return 1 ;;
    esac
  done
}

file_multi_handoffs() { # file_multi_handoffs <date> <"id id ..."> <body> → prints count filed
  # Splits an attribution-format body ('=== project: x ===' / '=== machine ===')
  # and files each well-formed note under its scope. Unknown ids are dropped:
  # the agent cannot invent projects, only file under ones on the roster.
  local now="$1" valid=" $2 machine " body="$3" cur="" chunk="" saved=0 line scope i found
  local scopes=() chunks=()
  while IFS= read -r line; do
    case "$line" in
      '=== project: '*' ==='|'=== machine ==='|'=== end ===')
        if [ -n "$cur" ] && handoff_body_complete "$chunk"; then
          case "$valid" in
            *" $cur "*)
              found=-1
              for i in "${!scopes[@]}"; do [ "${scopes[$i]}" = "$cur" ] && { found="$i"; break; }; done
              if [ "$found" -eq -1 ]; then
                scopes+=("$cur"); chunks+=("$chunk")
              else
                chunks[$found]+="${chunks[$found]:+$'\n'}$chunk"
              fi
              ;;
            *) warn "handoff for unknown scope '$cur' dropped" ;;
          esac
        fi
        cur="${line#=== }"; cur="${cur% ===}"; cur="${cur#project: }"; chunk="" ;;
      *) chunk+="$line"$'\n' ;;
    esac
  done <<< "$body"$'\n'"=== end ==="
  for i in "${!scopes[@]}"; do
    scope="${scopes[$i]}"
    if [ "$scope" = machine ]; then file_handoff "" "$now" "${chunks[$i]}"
    else file_handoff "$scope" "$now" "${chunks[$i]}"; fi
    saved=$((saved + 1))
  done
  printf '%s' "$saved"
}

# Set by resolve_candidate_handoffs for generate_handoff. Candidate arrays
# are local to generate_handoff and visible here through Bash's dynamic scope.
RESOLVED_HANDOFF_BODY=""
RESOLVED_PROJECT_IDS=""

resolve_candidate_handoffs() { # resolve candidate scopes after substantive work was identified
  local body="$1" token path identity id line scope k found
  local candidate_resolutions=()
  RESOLVED_PROJECT_IDS=""
  for k in "${!candidate_tokens[@]}"; do
    token="${candidate_tokens[$k]}"; candidate_resolutions[$k]=unknown
    case $'\n'"$body"$'\n' in
      *$'\n'"=== candidate: $token ==="$'\n'*) ;;
      *) continue ;;
    esac
    path="${candidate_paths[$k]}"; identity="${candidate_identities[$k]}"
    if [ -t 0 ]; then
      if confirm_yes "track Git repo $path ($identity) as a project?"; then
        if id="$(enroll_project "$path")"; then
          candidate_resolutions[$k]="project:$id"
          RESOLVED_PROJECT_IDS+="$id "
          info "tracking '$id' across the caravan"
        else
          candidate_resolutions[$k]=machine
          warn "could not track $identity; preserving its work in this machine's handoff"
        fi
      else
        ignore_repository "$identity"
        candidate_resolutions[$k]=machine
        info "ignoring $identity across the caravan (its work stays in this machine's handoff)"
      fi
    else
      # A noninteractive session cannot make a durable user choice. Preserve
      # the work in the machine handoff and leave the repository undecided.
      candidate_resolutions[$k]=machine
    fi
  done

  RESOLVED_HANDOFF_BODY=""
  while IFS= read -r line; do
    case "$line" in
      '=== candidate: '*' ===')
        token="${line#=== candidate: }"; token="${token% ===}"
        scope=unknown; found=-1
        for k in "${!candidate_tokens[@]}"; do
          [ "${candidate_tokens[$k]}" = "$token" ] && { found="$k"; break; }
        done
        [ "$found" -eq -1 ] || scope="${candidate_resolutions[$found]}"
        case "$scope" in
          project:*) RESOLVED_HANDOFF_BODY+="=== project: ${scope#project:} ==="$'\n' ;;
          machine)   RESOLVED_HANDOFF_BODY+="=== machine ==="$'\n' ;;
          *)         RESOLVED_HANDOFF_BODY+="=== unknown ==="$'\n' ;;
        esac
        ;;
      *) RESOLVED_HANDOFF_BODY+="$line"$'\n' ;;
    esac
  done <<< "$body"
}

compose_handoff_run_args() { # compose_handoff_run_args <agent> <home> <project>
  local agent="$1" home="$2" project="$3"
  # The handoff worker resumes the transcript and writes its answer to stdout.
  # It does not need the project, Sync Repo, skills, machine notes, clipboard,
  # SSH agent, or Host Session access. Keep its only durable mount read-write:
  # both CLIs store the resumed conversation in their agent home.
  RUN_ARGS=(--init --label "$MANAGED_CONTAINER_LABEL"
    -e HOME=/home/satchel -e "TERM=${TERM:-xterm-256color}"
    -e DISABLE_AUTOUPDATER=1
    -v "$home:/home/satchel"
    --user "$SATCHEL_UID:$SATCHEL_GID" --cap-drop ALL
    --security-opt no-new-privileges)
  # Claude and Codex select the conversation to resume partly by its original
  # cwd. Keep that exact path without mounting the real project: an empty
  # tmpfs satisfies engines (notably Podman) that reject a nonexistent -w
  # directory, and disappears with the helper container.
  if [ "$project" != / ]; then
    RUN_ARGS+=(--tmpfs "$project:rw,nosuid,nodev,noexec,mode=1777")
  fi
  RUN_ARGS+=(-w "$project")
  if selinux_active; then RUN_ARGS+=(--security-opt label=disable); fi
  if podman_rootless; then
    RUN_ARGS+=(--userns=keep-id --passwd-entry '$USERNAME:*:$UID:$GID::/home/satchel:/bin/bash')
  fi
  return 0
}

run_isolated_task() { # protect <command...> | cancellable <stdout-file> <stderr-file> <command...>
  local mode="$1"; shift
  local outf="" errf="" task_pid="" rc=0 cancelled=0 had_monitor=0 old_int old_quit
  case "$mode" in
    protect) ;;
    cancellable) outf="$1"; errf="$2"; shift 2 ;;
    *) return 2 ;;
  esac
  old_int="$(trap -p INT)"
  old_quit="$(trap -p QUIT)"
  case "$-" in *m*) had_monitor=1 ;; esac

  # Some programs install their own signal handlers even when Satchel ignores
  # SIGINT. Every task gets a separate process group so terminal Ctrl-C stays
  # with Satchel. Protected cleanup ignores Ctrl-\ too; a cancellable handoff
  # uses it to terminate the isolated task group and returns status 131.
  trap '' INT
  case "$mode" in
    protect) trap '' QUIT ;;
    cancellable)
      trap 'cancelled=1; [ -z "$task_pid" ] || kill -TERM -- "-$task_pid" 2>/dev/null || true' QUIT
      ;;
  esac
  set -m
  if [ "$mode" = cancellable ]; then
    "$@" >"$outf" 2>"$errf" &
  else
    "$@" &
  fi
  task_pid=$!
  wait "$task_pid" || rc=$?
  if [ "$cancelled" -eq 1 ]; then
    # QUIT can interrupt wait before the task group has fully exited.
    wait "$task_pid" 2>/dev/null || true
    rc=131
  fi
  [ "$had_monitor" -eq 1 ] || set +m
  trap - INT QUIT
  [ -z "$old_int" ] || eval "$old_int"
  [ -z "$old_quit" ] || eval "$old_quit"
  return "$rc"
}

generate_handoff() { # generate_handoff <agent> <slug> <project>  — runs after the session ends; empty slug = machine scope
  local agent="$1" slug="$2" project="$3"
  local now scope prompt
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # One visible project that is also the launch scope needs no attribution;
  # anything more gets the multi-scope prompt so work files under each
  # project it actually happened in, no matter how the session was launched.
  local vis_paths=() vis_ids=() vp vi multi=0
  while IFS=$'\t' read -r vp vi; do vis_paths+=("$vp"); vis_ids+=("$vi"); done < <(visible_projects "$project")
  local candidate_tokens=() candidate_paths=() candidate_identities=() candidate_rosters=()
  local cp ci token n=0 k found
  while IFS=$'\t' read -r cp ci; do
    found=-1
    for k in "${!candidate_identities[@]}"; do
      [ "${candidate_identities[$k]}" = "$ci" ] && { found="$k"; break; }
    done
    if [ "$found" -eq -1 ]; then
      n=$((n + 1)); token="candidate-$n"; candidate_tokens+=("$token")
      candidate_paths+=("$cp"); candidate_identities+=("$ci"); candidate_rosters+=("")
      found=$((${#candidate_tokens[@]} - 1))
    fi
    token="${candidate_tokens[$found]}"
    candidate_rosters[$found]+="- unknown Git repo $token: $(session_path "$cp") ($ci)"$'\n'
  done < <(visible_candidates "$project")
  if [ ${#vis_ids[@]} -gt 1 ]; then multi=1
  elif [ ${#vis_ids[@]} -eq 1 ] && [ "${vis_ids[0]}" != "$slug" ]; then multi=1
  elif [ ${#candidate_tokens[@]} -gt 0 ]; then multi=1
  fi
  if [ "$multi" -eq 1 ]; then
    local roster="" k
    for k in "${!vis_ids[@]}"; do
      roster+="- tracked project ${vis_ids[$k]}: $(session_path "${vis_paths[$k]}")"$'\n'
    done
    for k in "${!candidate_tokens[@]}"; do
      roster+="${candidate_rosters[$k]}"
    done
    prompt="The session is ending. These tracked projects and unknown Git repositories were visible in this session:
${roster}Write a handoff note for each tracked project you actually worked in. For each unknown Git repo, write a separate candidate note only if substantive continuation-worthy work occurred there: editing, debugging, planning, or decisions worth resuming. Merely discovering, listing, or casually reading a repo is not substantive. If meaningful work also happened outside every tracked project and candidate, add one machine note.

Start tracked notes with exactly '=== project: <id> ===', candidate notes with exactly '=== candidate: <candidate-N> ===', and the machine note with exactly '=== machine ==='. Follow each delimiter with ## Goal, ## Done, ## In flight, ## Next steps, ## Gotchas. Under 30 lines per note. Skip scopes you did not substantively work in. If there is no meaningful work, output exactly NO_HANDOFF and nothing else. Output only the markdown, no preamble."
  else
    scope=machine; [ -n "$slug" ] && scope=project
    prompt="The session is ending. Based on this conversation, write a handoff note so the next session on this $scope can continue where we left off. Use exactly these sections: ## Goal, ## Done, ## In flight, ## Next steps, ## Gotchas. Under 30 lines total. If you did no meaningful work to hand off, output exactly NO_HANDOFF and nothing else. Output only the markdown, no preamble."
  fi
  # A handoff is a summary chore in a fixed format — the small fast model is
  # plenty and halves the wait at session end. Override per agent via
  # 'satchel settings'; empty means the agent's own default model.
  local base_cmd model setting
  case "$agent" in
    claude)
      base_cmd=(claude --continue --strict-mcp-config --tools "" --effort low -p "$prompt")
      model="${SATCHEL_HANDOFF_MODEL_CLAUDE-haiku}"; setting=SATCHEL_HANDOFF_MODEL_CLAUDE ;;
    codex)
      # --skip-git-repo-check: codex exec hard-fails in a non-git project dir
      # (interactive codex remembers trust; exec does not).
      # Codex has no rolling cheap-model alias (any pinned name would rot),
      # so the speed lever is reasoning effort on the default model instead.
      base_cmd=(codex exec resume --last --skip-git-repo-check --ignore-user-config --ignore-rules -c 'sandbox_mode="danger-full-access"' -c 'model_reasoning_effort="low"' "$prompt")
      model="${SATCHEL_HANDOFF_MODEL_CODEX-}"; setting=SATCHEL_HANDOFF_MODEL_CODEX ;;
  esac
  local cmd=("${base_cmd[@]}")
  case "$agent:$model" in
    claude:?*) cmd=(claude --continue --strict-mcp-config --tools "" --model "$model" --effort low -p "$prompt") ;;
    codex:?*)  cmd=(codex exec resume --last --skip-git-repo-check --ignore-user-config --ignore-rules -c 'sandbox_mode="danger-full-access"' -c 'model_reasoning_effort="low"' -m "$model" "$prompt") ;;
  esac

  compose_handoff_run_args "$agent" "$HOMES_DIR/$agent" "$project"

  info "writing handoff… (Ctrl-\\ skips it)"
  # A held Ctrl-C used to exit the interactive agent can keep sending INT
  # after the agent is gone. Ignore that spillover while writing the handoff;
  # Ctrl-\ (QUIT) is the distinct, deliberate escape hatch.
  # stderr goes to a scratch file so a failure can say WHY (a swallowed
  # "--skip-git-repo-check was not specified" once hid this for days).
  local body="" rc=0 errf bodyf
  errf="$(mktemp)"
  bodyf="$(mktemp)"
  run_isolated_task cancellable "$bodyf" "$errf" \
    timeout 240 "$(engine)" run --rm "${RUN_ARGS[@]}" "$IMAGE" "${cmd[@]}" || rc=$?
  body="$(<"$bodyf")"
  if [ "$rc" -eq 131 ]; then
    rm -f "$errf" "$bodyf"
    warn "handoff skipped — previous handoff kept"
    return 0
  fi
  # NO_HANDOFF is the agent saying "nothing worth handing off" (a Q&A-only
  # session) — a valid outcome, not a model failure. Accept it only from a
  # successful writer; partial output from a failed command is not authoritative.
  if [ "$rc" -eq 0 ] && [ "$body" = NO_HANDOFF ]; then
    rm -f "$errf" "$bodyf"
    info "no work to hand off — previous handoff kept"
    return 0
  fi
  if [ "$rc" -ne 0 ] || ! handoff_body_complete "$body"; then
    # Fatfingered model safeguard: a bad SATCHEL_HANDOFF_MODEL_* must not stop
    # handoffs — retry once on the agent's own default and say who to blame.
    if [ -n "$model" ]; then
      warn "handoff model '$model' failed — retrying with the agent's default (fix with: satchel settings $setting <model>)"
      rc=0
      run_isolated_task cancellable "$bodyf" "$errf" \
        timeout 240 "$(engine)" run --rm "${RUN_ARGS[@]}" "$IMAGE" "${base_cmd[@]}" || rc=$?
      body="$(<"$bodyf")"
      if [ "$rc" -eq 131 ]; then
        rm -f "$errf" "$bodyf"
        warn "handoff skipped — previous handoff kept"
        return 0
      fi
    fi
    if [ "$rc" -eq 0 ] && [ "$body" = NO_HANDOFF ]; then
      rm -f "$errf" "$bodyf"
      info "no work to hand off — previous handoff kept"
      return 0
    fi
    if [ "$rc" -ne 0 ] || ! handoff_body_complete "$body"; then
      warn "handoff generation failed — keeping the previous handoff"
      if [ -s "$errf" ]; then
        warn "the agent said: $(tail -n 1 "$errf")"
      fi
      rm -f "$errf" "$bodyf"
      return 0
    fi
  fi
  rm -f "$errf" "$bodyf"
  if [ "$multi" -eq 1 ]; then
    local ids="" saved savedf
    for vi in "${vis_ids[@]}"; do ids+="$vi "; done
    if [ ${#candidate_tokens[@]} -gt 0 ]; then
      resolve_candidate_handoffs "$body"
      body="$RESOLVED_HANDOFF_BODY"; ids+="$RESOLVED_PROJECT_IDS"
    fi
    savedf="$(mktemp)"
    run_isolated_task protect file_multi_handoffs "$now" "$ids" "$body" > "$savedf"
    saved="$(<"$savedf")"
    rm -f "$savedf"
    [ "$saved" -gt 0 ] \
      || warn "handoff attribution was incomplete — keeping the previous handoff"
  else
    run_isolated_task protect file_handoff "$slug" "$now" "$body"
  fi
  return 0
}
