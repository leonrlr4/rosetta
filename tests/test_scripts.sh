#!/usr/bin/env bash
# The shell scripts: syntax, and the defaults they must share with Overlay.qml.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok $1"; else echo "FAIL $1: expected '$3', got '$2'"; fail=1; fi; }

for f in bin/rosetta scripts/setup; do
  bash -n "$f" && echo "ok syntax $f" || { echo "FAIL syntax $f"; fail=1; }
done

# setup pulls the models the overlay asks for; a default changed in one place
# only would leave the key opening a "model not found" error.
qml_model() { grep -A4 "^    $1: {" Overlay.qml | grep -oP 'model: "\K[^"]+'; }
setup_model() { grep -oP "model_of $1 \"\K[^\"]+" scripts/setup; }
check "translate model matches" "$(setup_model translate)" "$(qml_model translate)"
check "explain model matches" "$(setup_model explain)" "$(qml_model explain)"

# --check never changes anything, and refuses a key that could break the Lua.
out=$(bash scripts/setup --check --key 'SUPER + D") os.execute("x' 2>&1); code=$?
check "bad key is refused" "$code" "2"

exit $fail
