#!/usr/bin/env bash

VERSION="1.0.4"
BASE_DIR="/home/courses"

# Self-update
SELF="$(realpath "$0")"
REMOTE_SELF="https://raw.githubusercontent.com/qiaochloe/unified-containers/main/cscourse.sh"

# Global logging
LOG="$BASE_DIR/.cscourse/metadata.csv"

declare -A COURSE_REPOS
COURSE_REPOS=(
  [300]="https://github.com/csci0300/cs300-s24-devenv.git"
  [example]="https://github.com/qiaochloe/example-course-repo.git"
)

# Check that the base directory exists and is a mount
# Check that .cscourse/metadata.csv exists
init() {
  # Base directory
  if [[ ! -d "$BASE_DIR" ]]; then
    echo "$BASE_DIR does not exist. Did you change the name?"
    exit 1
  fi

  if ! mountpoint -q "$BASE_DIR"; then
    echo "$BASE_DIR is not a mountpoint. Did you mount the directory?"
    exit 1
  fi

  # Metadata
  mkdir -p "$(dirname "$METADATA_DIR")"
  if [[ ! -f "$LOG" ]]; then
    echo "ID,COURSE,COURSE_REPO,COMMIT,DIRPATH" >"$LOG"
  fi

  # Index
  build_course_index
}

# Setup a new course
setup_course() {
  local course="$1"

  # Get the remote course repository URL from courses.json
  local course_repo="${COURSE_REPOS[$course]}"
  if [[ -z "$course_repo" ]]; then
    echo "Could not find remote course repository for '$course'"
    exit 1
  fi

  # Get a new name for dirpath
  local dirname="$course"
  local base="$BASE_DIR/$course"
  local dirpath="$base"
  local i=1
  while [[ -e "$dirpath" ]]; do
    dirpath="${base}-$i"
    ((i++))
  done

  # Clone the repository
  echo "Cloning $course repo to $dirpath"
  git clone "$course_repo" "$dirpath"

  log_course "$course" "$course_repo" "$dirpath"
  run_course_setup "$dirpath"
}

# Logging utilities
get_id() {
  local course="$1"
  local course_repo="$2"
  local hash_input="$course-$course_repo-$(date +%s)"
  echo -n "$hash_input" | sha256sum | cut -c1-8
}

get_commit() {
  local dirpath="$1"
  if [[ -d "$dirpath/.git" ]]; then
    git -C "$dirpath" rev-parse HEAD 2>/dev/null
  else
    echo "unknown"
  fi
}

get_last_entry() {
  local log="$1"
  tail -n +2 "$log" | tail -n 1
}

# Log course metadata in local course directory
log_course() {
  local course="$1"
  local course_repo="$2"
  local dirpath="$3"
  local id=$(get_id $course $course_repo)
  local commit=$(get_commit "$dirpath")

  local log="$dirpath/.cscourse/metadata.csv"
  if [[ ! -f "$log" ]]; then
    mkdir -p $(dirname "$log")
    echo "ID,COURSE,COURSE_REPO,COMMIT,DIRPATH" >"$log"
  fi

  echo "$id,$course,$course_repo,$commit,$dirpath" >>"$log"
}

# Run the setup script for a course
run_course_setup() {
  local dirpath="$1"

  # Run the setup script
  local script="$dirpath/setup.sh"
  if [[ ! -f "$script" ]]; then
    echo "Error: No setup.sh found in $dirpath"
    return 0
  fi

  echo "Running setup for $course..."
  chmod +x "$script"

  # TODO: decide whether to sandbox
  if command -v sandbox >/dev/null 2>&1; then
    sandbox "$id" "$script"
  else
    echo "Warning: 'sandbox' not found, running directly..."
    bash "$script"
  fi
}

# Upgrade course
upgrade_course() {
  local id="$1"
  local line=$(tac "$LOG" | grep -m 1 "^$id,")

  if [[ -z "$line" ]]; then
    echo "Error: No course found with ID $id"
    return 1
  fi

  local line=$(tac "$LOG" | grep -m 1 "^$id,")
  IFS=',' read -r line_id line_course line_course_repo line_commit line_dirpath <<<"$line"

  if [[ ! -d "$dirpath" ]]; then
    echo "Error: $dirpath does not exist"
    return 1
  fi
  if [[ ! -d "$dirpath/.git" ]]; then
    echo "Error: $dirpath is not a git repo"
    return 1
  fi

  echo "Updating course in $dirpath..."
  git -C "$dirpath" pull

  # Run the bash script again
  run_course_setup "$dirpath"
}

# Update cscourse.sh with the latest version from remote repository
update_self() {
  echo "Checking for latest version of cscourse..."
  TMPFILE=$(mktemp)
  if curl -sSfL "$REMOTE_SELF" -o "$TMPFILE"; then
    if ! cmp -s "$SELF" "$TMPFILE"; then
      chmod +x "$TMPFILE"
      cp "$TMPFILE" "$SELF"
      local new_version=$(grep -E '^VERSION=' "$TMPFILE" | cut -d= -f2 | tr -d '"')
      echo "Updated to latest version $new_version"
    else
      echo "Already up to date"
    fi
  else
    echo "Failed to check for update"
  fi
  rm -f "$TMPFILE"
}

# List downloaded courses
list_courses() {
  column -s, -t <"$LOG"
}

# Build course index in the root of the course directory
# which combines metadata from <course>/.cscourse/metadata.csv
build_course_index() {
  local tmp=$(mktemp)
  echo "ID,COURSE,COURSE_REPO,COMMIT,DIRPATH" >"$tmp"

  for dirpath in "$BASE_DIR"/*; do
    [[ -d "$dirpath" ]] || continue
    local log="$dirpath/.cscourse/metadata.csv"

    # Get the course-repo and course
    local course_repo=$(git -C "$dirpath" remote get-url origin 2>/dev/null)
    if [[ "$?" -ne 0 ]]; then continue; fi

    local course=""
    for c in "${!COURSE_REPOS[@]}"; do
      if [[ "${COURSE_REPOS[$c]}" == "$course_repo" ]]; then
        course="$c"
        break
      fi
    done
    if [[ -z "$course" ]]; then continue; fi

    # If a directory does not have a metadata file with an entry
    # then try to create one and run the setup script
    if [[ ! -f $log ]]; then
      log_course "$course" "$course_repo" "$dirpath"
      run_course_setup "$dirpath"
    else
      # If the metadata file exists, make sure that the entry is up to date
      local last_entry="$(get_last_entry "$log")"
      IFS=',' read -r line_id line_course line_course_repo line_commit line_dirpath <<<"$last_entry"
      local new_entry="$line_id,$course,$course_repo,$(get_commit "$dirpath"),$dirpath"

      if [[ ! "$new_entry" == "$last_entry" ]]; then
        echo "$new_entry" >>"$log"
      fi
    fi

    # Read the last line of the metadata file and record it in TMP
    local last_entry="$(get_last_entry "$log")"
    echo "$last_entry" >>"$tmp"
  done

  mv "$tmp" "$LOG"
}

# Usage
usage() {
  echo "Usage $0:"
  echo "Commands:"
  echo " setup <course>     Clone and run course setup"
  echo " upgrade <id>       Upgrade course to the latest version"
  echo " list               List downloaded courses"
  echo " update             Update cscourse to the latest version"
  echo ""

  echo "Available courses:"
  for course in "${!COURSE_REPOS[@]}"; do
    echo " $course"
  done

  exit 0
}

main() {
  init

  # cscourse update
  if [[ "$#" -eq 1 && "$1" == "update" ]]; then
    update_self
    exit 0
  fi

  # cscourse list
  if [[ "$#" -eq 1 && "$1" == "list" || "$1" == "ls" ]]; then
    list_courses
    exit 0
  fi

  # cscourse setup <course>
  if [[ "$#" -eq 2 && "$1" == "setup" || "$1" == "s" ]]; then
    setup_course "$2"
    exit 0
  fi

  # cscourse upgrade <course>
  if [[ "$#" -eq 2 && "$1" == "upgrade" ]]; then
    upgrade_course "$2"
    exit 0
  fi

  if [[ "$#" -ge 1 ]]; then
    echo "Error: Invalid command: $*"
  fi

  usage
}

main "$@"
