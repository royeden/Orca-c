#!/usr/bin/env bash
set -eu -o pipefail

print_usage() {
cat <<EOF
Usage: tool [options] command [args]
Commands:
    build <config> <target>
        Compile orca.
        Configs: debug, release
        Targets: orca, tui
        Output: build/<config>/<target>
    clean
        Removes build/
    info
        Prints information about the detected build environment.
Options:
    -v            Print important commands as they're executed.
    -c <name>     Use a specific compiler binary.
                  Default: \$CC, or cc
    -d            Enable compiler safeguards like -fstack-protector.
                  You should probably do this if you plan to give the
                  compiled binary to other people.
    -p            Enable PIE (ASLR)
    -s            Print statistics about compile time and binary size.
    -h or --help  Print this message and exit.
EOF
}

os=
case $(uname -s | awk '{print tolower($0)}') in
  linux*) os=linux;;
  darwin*) os=mac;;
  cygwin*) os=cygwin;;
  *bsd*) os=bsd;;
  *) os=unknown;;
esac

cc_exe="${CC:-cc}"

verbose=0
protections_enabled=0
stats_enabled=0
pie_enabled=0

while getopts c:dhpsv-: opt_val; do
  case "$opt_val" in
    -)
      case "$OPTARG" in
        help) print_usage; exit 0;;
        *)
          echo "Unknown long option --$OPTARG" >&2
          print_usage >&2
          exit 1
          ;;
      esac
      ;;
    c) cc_exe="$OPTARG";;
    d) protections_enabled=1;;
    h) print_usage; exit 0;;
    p) pie_enabled=1;;
    s) stats_enabled=1;;
    v) verbose=1;;
    \?) print_usage >&2; exit 1;;
    *) break;;
  esac
done

warn() {
  echo "Warning: $*" >&2
}
fatal() {
  echo "Error: $*" >&2
  exit 1
}
script_error() {
  echo "Script error: $*" >&2
  exit 1
}

verbose_echo() {
  if [[ $verbose = 1 ]]; then
    echo "$@"
  fi
  "$@"
}

TIMEFORMAT='%3R'

last_time=

file_size() {
  wc -c < "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

timed_stats() {
  if [[ $stats_enabled = 1 ]]; then
    { last_time=$( { time "$@" 1>&3- 2>&4-; } 2>&1 ); } 3>&1 4>&2
  else
    "$@"
  fi
}

if [[ ($os == bsd) || ($os == unknown) ]]; then
  warn "Build script not tested on this platform"
fi

# This is not perfect by any means
cc_id=
cc_vers=
lld_detected=0
if cc_vers_string=$("$cc_exe" --version 2> /dev/null); then
  if clang_vers_string=$(echo "$cc_vers_string" | grep clang | head -n1) && ! [[ -z $clang_vers_string ]]; then
    cc_id=clang
    # clang -dumpversion always pretends to be gcc 4.2.1
    # shellcheck disable=SC2001
    cc_vers=$(echo "$clang_vers_string" | sed 's/.*version \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/')
    if [[ $os != mac ]]; then
      if command -v "lld" >/dev/null 2>&1; then
        lld_detected=1
      fi
    fi
  # Only gcc has -dumpfullversion
  elif cc_vers=$("$cc_exe" -dumpfullversion 2> /dev/null); then
    cc_id=gcc
  fi
fi

if [[ -z $cc_id ]]; then
  warn "Failed to detect compiler type"
fi
if [[ -z $cc_vers ]]; then
  warn "Failed to detect compiler version"
fi

add() {
  if [[ -z "${1:-}" ]]; then
    script_error "At least one argument required for array add"
  fi
  local array_name
  array_name=${1}
  shift
  eval "$array_name+=($(printf "'%s' " "$@"))"
}

try_make_dir() {
  if ! [[ -e "$1" ]]; then
    verbose_echo mkdir "$1"
  elif ! [[ -d "$1" ]]; then
    fatal "File $1 already exists but is not a directory"
  fi
}

build_dir=build

build_target() {
  local build_subdir
  local cc_flags=()
  local libraries=()
  local source_files=()
  local out_exe
  add cc_flags -std=c99 -pipe -Wall -Wpedantic -Wextra -Wconversion -Werror=implicit-function-declaration -Werror=implicit-int -Werror=incompatible-pointer-types -Werror=int-conversion
  if [[ $lld_detected = 1 ]]; then
    add cc_flags -fuse-ld=lld
  fi
  if [[ $protections_enabled = 1 ]]; then
    add cc_flags -D_FORTIFY_SOURCE=2 -fstack-protector-strong
  fi
  if [[ $pie_enabled = 1 ]]; then
    add cc_flags -fpie
    if [[ $lld_detected = 1 ]]; then
      # LLD seems to need this or it fails at linking. If we also pass -Wl,-pie
      # then the built binary will crash before reaching main().
      add cc_flags -Wl,-z,notext
    else
      # This is the one that works everywhere else.. hmm
      add cc_flags -Wl,-pie
    fi
  fi
  case "$1" in
    debug)
      build_subdir=debug
      add cc_flags -DDEBUG -ggdb -fsanitize=address -fsanitize=undefined
      if [[ $os = mac ]]; then
        # mac clang does not have -Og
        add cc_flags -O1
        # tui in the future
        # add libraries -lncurses
      else
        add cc_flags -Og
        # needed if address is already specified? doesn't work on mac clang, at
        # least
        # add cc_flags -fsanitize=leak
        # add libraries -lncursesw
      fi
      ;;
    release)
      build_subdir=release
      add cc_flags -DNDEBUG -O2 -g0
      if [[ $protections_enabled != 1 ]]; then
        add cc_flags -fno-stack-protector
      fi
      if [[ $os = mac ]]; then
        # todo some stripping option
        true
      else
        # -flto is good on both clang and gcc on Linux
        add cc_flags -flto -s
      fi
      ;;
    *) fatal "Unknown build config \"$1\"";;
  esac
  add source_files field.c mark.c bank.c sim.c
  case "$2" in
    orca|cli)
      add source_files cli_main.c
      out_exe=orca
      ;;
    tui)
      add source_files tui_main.c
      add cc_flags -D_XOPEN_SOURCE_EXTENDED=1
      out_exe=tui
      if [[ $os = mac ]]; then
        add libraries -lncurses
      else
        add libraries -lncursesw
      fi
      ;;
  esac
  try_make_dir "$build_dir"
  try_make_dir "$build_dir/$build_subdir"
  local out_path=$build_dir/$build_subdir/$out_exe
  # bash versions quirk: empty arrays might give error on expansion, use +
  # trick to avoid expanding second operand
  verbose_echo timed_stats "$cc_exe" "${cc_flags[@]}" -o "$out_path" "${source_files[@]}" ${libraries[@]+"${libraries[@]}"}
  if [[ $stats_enabled = 1 ]]; then
    echo "time: $last_time"
    echo "size: $(file_size "$out_path")"
  fi
}

print_info() {
  local linker_name
  if [[ $lld_detected = 1 ]]; then
    linker_name=LLD
  else
    linker_name=default
  fi
  cat <<EOF
Operating system: $os
Compiler name:    $cc_exe
Compiler type:    $cc_id
Compiler version: $cc_vers
Linker:           $linker_name
EOF
}

shift $((OPTIND - 1))

if [[ -z "${1:-}" ]]; then
  echo "Error: Command required" >&2
  print_usage >&2
  exit 1
fi

case "$1" in
  info)
    if [[ "$#" -gt 1 ]]; then
      fatal "Too many arguments for 'info'"
    fi
    print_info
    exit 0
    ;;
  build)
    if [[ "$#" -lt 3 ]]; then
      fatal "Too few arguments for 'build'"
    fi
    if [[ "$#" -gt 3 ]]; then
      fatal "Too many arguments for 'build'"
    fi
    build_target "$2" "$3"
    ;;
  clean)
    if [[ -d "$build_dir" ]]; then
      verbose_echo rm -rf "$build_dir"
    fi
    ;;
  *) fatal "Unrecognized command $1";;
esac
