#!/bin/sh
# The suite, on every pair of OTP and Elixir that is named.
#
#     scripts/matrix.sh "26.2.5.21 1.18.5-otp-26" "27.3.4.18 1.18.5-otp-27" "29.1.1 1.20.4-otp-29"
#
# Each pair is run by mise, which has to have both installed, with a build
# directory of its own, so that one run is not the next one's leftovers.
#
# A test of one VM is skipped on every other: what a collector does
# without trace sessions is tested on OTP 26 and nowhere else. So a
# release is run on each, and not on the newest alone.

set -u

work=${MATRIX_WORK:-${TMPDIR:-/tmp}/timeless_beam_acct_matrix}
mkdir -p "$work"
cd "$(dirname "$0")/.." || exit 1

# A node that is distributed writes ~/.erlang.cookie if there is none.
# The tests that start other nodes are shown one of their own instead.
mkdir -p "$work/xdg/erlang"
if [ ! -f "$work/xdg/erlang/.erlang.cookie" ]; then
  printf 'not_the_cookie_of_any_cluster' > "$work/xdg/erlang/.erlang.cookie"
  chmod 400 "$work/xdg/erlang/.erlang.cookie"
fi
export XDG_CONFIG_HOME="$work/xdg"

failed=0

for pair in "$@"; do
  set -- $pair
  otp=$1
  elixir=$2
  home="$work/mix_home_${otp}_${elixir}"
  run="mise exec erlang@$otp elixir@$elixir --"

  export MIX_ENV=test
  export MIX_HOME="$home"
  export MIX_ARCHIVES="$home/archives"
  export MIX_BUILD_PATH="$work/build_${otp}_${elixir}"

  echo "=== OTP $otp, Elixir $elixir"

  # An Elixir that has just been installed has no Hex, and mix asks
  # whether to install it and waits to be answered.
  if [ ! -d "$home/archives" ]; then
    mkdir -p "$home/archives"
    $run mix local.hex --force < /dev/null > "$work/hex_${otp}_${elixir}.log" 2>&1
    $run mix local.rebar --force < /dev/null >> "$work/hex_${otp}_${elixir}.log" 2>&1
  fi

  log="$work/test_${otp}_${elixir}.log"

  if $run mix test --warnings-as-errors < /dev/null > "$log" 2>&1; then
    grep -E "Result|tests, .*failures" "$log" | tail -1
  else
    failed=1
    grep -E "^ +[0-9]+\) test|Result|tests, .*failures|\*\* \(|aborted" "$log" | head -20
    echo "failed: see $log"
  fi
done

rm -f erl_crash.dump
exit $failed
