#!/usr/bin/env bash
#
# The OpenTofu template (scripts/terraform) against the bash templates it
# mirrors, then its own checks: format, validate and the unit tests (mocked
# provider, no daemon needed).
#
#   tests/terraform.sh          # check
#   tests/terraform.sh --fix    # first rewrite guest/<distro>.sh and tests/terraform.tfvars
#
# Mirrored: guest/<distro>.sh is the provisioning heredoc of
# create_incus_<distro>.sh byte for byte, the distro table of main.tf holds each
# script's image, user and mirror, every setting of the scripts has a variable
# with the same default, and the provisioning gets the same environment.
#
# tests/terraform.tfvars holds every variable at its default: tofu test loads it
# over TF_VAR_* and over the tfvars files next to main.tf, so the unit tests do
# not depend on how a copy is configured. They run here with all of those set
# to other values, which proves it.
#
# Needs tofu (TOFU=... for another binary, TOFU=terraform for HashiCorp
# Terraform) and python3; `tofu init` downloads the provider unless a local
# mirror has it.
set -euo pipefail
cd "$(dirname "$0")/.."

TOFU="${TOFU:-tofu}"
tf="${TOFU##*/}" # for the messages
TPL=scripts/terraform
DISTROS="alpine debian13 ubuntu2404 ubuntu2604 fedora"
fix=false
[ "${1:-}" != --fix ] || fix=true
failed=0

ok() { printf '\033[32mok\033[0m   %s\n' "$*"; }
bad() {
	printf '\033[31mFAIL\033[0m %s\n' "$*" >&2
	failed=1
}

heredoc() { sed -n "/<<'GUEST'\$/,/^GUEST\$/p" "scripts/create_incus_$1.sh" | sed '1d;$d'; }

# NAME<TAB>VALUE for each `: "${NAME:=default}"` line of a script, evaluated by
# bash itself with an empty environment.
bash_defaults() {
	local lines names
	lines="$(grep -E '^: "\$\{[A-Z0-9_]+:?=' "scripts/create_incus_$1.sh")"
	names="$(sed -E 's/^: "\$\{([A-Z0-9_]+).*/\1/' <<<"$lines" | tr '\n' ' ')"
	env -i bash -c "$lines"$'\n'"for n in $names; do printf '%s\t%s\n' \"\$n\" \"\${!n}\"; done"
}

# The --env names the script hands to its provisioning.
bash_env() { grep -oE -- '--env "[A-Z0-9_]+=' "scripts/create_incus_$1.sh" | sed -E 's/--env "//; s/=$//' | sort; }

# tests/terraform.tfvars as variables.tf defines it.
test_tfvars() {
	python3 -I - "$TPL/variables.tf" <<'PY' | "$TOFU" fmt -
import json, re, sys

print("""\
# Every variable at its default, for tofu test only: loaded over TF_VAR_* and
# over the tfvars files next to main.tf, so the unit tests do not depend on how
# this copy is configured. Generated from variables.tf (in the image's
# repository: tests/terraform.sh --fix).""")
for name, body in re.findall(r'^variable "(\w+)" \{\n(.*?)^\}', open(sys.argv[1]).read(), re.S | re.M):
    m = re.search(r'^  default\s*=\s*(.+)$', body, re.M)
    if not m:
        sys.exit(f"variables.tf: {name} has no default, the unit tests need one")
    value = json.dumps(json.loads(m.group(1))).replace("${", "$${").replace("%{", "%%{")
    print(f"{name} = {value}")
PY
}

if $fix; then test_tfvars >"$TPL/tests/terraform.tfvars"; fi
if cmp -s <(test_tfvars) "$TPL/tests/terraform.tfvars"; then
	ok "tests/terraform.tfvars has every variable at its default"
else
	bad "tests/terraform.tfvars differs from the defaults of variables.tf (tests/terraform.sh --fix):"
	diff -u <(test_tfvars) "$TPL/tests/terraform.tfvars" | head -20 >&2 || true
fi

for d in $DISTROS; do
	if $fix; then heredoc "$d" >"$TPL/guest/$d.sh"; fi
	if cmp -s <(heredoc "$d") "$TPL/guest/$d.sh"; then
		ok "guest/$d.sh is the heredoc of create_incus_$d.sh"
	else
		bad "guest/$d.sh differs from the heredoc of create_incus_$d.sh (tests/terraform.sh --fix):"
		diff -u <(heredoc "$d") "$TPL/guest/$d.sh" | head -20 >&2 || true
	fi

	out="$(python3 -I - "$d" "$TPL/variables.tf" "$TPL/main.tf" \
		3<<<"$(bash_defaults "$d")" 4<<<"$(bash_env "$d")" <<'PY'
import json, os, re, sys

distro, variables_tf, main_tf = sys.argv[1:4]
bash = dict(l.split("\t", 1) for l in os.fdopen(3).read().splitlines() if l)
bash_env = set(os.fdopen(4).read().split())
problems = []

# variable defaults: every one of variables.tf is a JSON literal
tf = {}
for name, body in re.findall(r'^variable "(\w+)" \{\n(.*?)^\}', open(variables_tf).read(), re.S | re.M):
    m = re.search(r'^  default\s*=\s*(.+)$', body, re.M)
    if m:
        tf[name] = json.loads(m.group(1))

main = open(main_tf).read()
table = {m[0]: {"image": m[1], "user": m[2], "probe": m[3]} for m in re.findall(
    r'^\s+(\w+)\s+=\s+\{ image = "([^"]+)", user = "([^"]+)", probe = "([^"]+)" \}$', main, re.M)}
row = table.get(distro)
if row is None:
    sys.exit(f"main.tf: no row for {distro} in the distros table")

def as_bash(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(int(v)) if float(v).is_integer() else str(v)
    if isinstance(v, list):
        return " ".join(as_bash(x) for x in v)
    if isinstance(v, dict):
        return " ".join(f"{k}={as_bash(x)}" for k, x in v.items())
    return v

# bash setting -> what the template has for it
special = {
    "INCUS_REMOTE": as_bash(tf.get("remote")),
    "INSTANCE_NAME": f"{distro}-dev",  # "${var.distro}-dev"
    "INSTANCE_IMAGE": row["image"],
    "USER_NAME": row["user"],
    "INSTANCE_RECREATE": None,  # tofu apply -replace=incus_instance.this
}
for name, value in bash.items():
    if name in special:
        want = special[name]
        if want is not None and want != value:
            problems.append(f"{name}: bash {value!r}, template {want!r}")
        continue
    var = name.lower()
    if var not in tf:
        problems.append(f"{name}: no variable {var} in variables.tf")
    elif as_bash(tf[var]) != value:
        problems.append(f"{name}: bash {value!r}, variables.tf {as_bash(tf[var])!r}")

# the mirror the script waits for
probe = re.search(r"getent hosts (\S+) >/dev/null", open(f"scripts/create_incus_{distro}.sh").read())
if not probe or probe.group(1) != row["probe"]:
    problems.append(f"probe: bash {probe and probe.group(1)!r}, main.tf {row['probe']!r}")

# the provisioning's environment
block = re.search(r"^  guest_env = merge\(\n(.*?)^  \)$", main, re.S | re.M)
tf_env = set(re.findall(r"^\s+([A-Z][A-Z0-9_]+)\s+=", block.group(1), re.M)) if block else set()
tf_env |= set(re.findall(r"\{ ([A-Z][A-Z0-9_]+) = var\.\w+ \}", block.group(1))) if block else set()
if distro == "alpine":
    tf_env.discard("DOCKER_SOURCE")  # left out for alpine
if tf_env != bash_env:
    problems.append(f"provisioning env: only bash {sorted(bash_env - tf_env)}, only template {sorted(tf_env - bash_env)}")

print("\n".join("       " + p for p in problems))
PY
	)" || {
		bad "$d: $out"
		continue
	}
	if [ -z "$out" ]; then
		ok "$d: settings, defaults, image, user, mirror and provisioning env match the bash template"
	else
		bad "$d: the template does not mirror create_incus_$d.sh:"
		printf '%s\n' "$out" >&2
	fi
done

# fmt, init, validate and test on a copy: nothing is written into the repository.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$TPL/." "$tmp/"
rm -rf "$tmp/.terraform" "$tmp"/*.tfstate* "$tmp"/terraform.tfvars

if "$TOFU" -chdir="$tmp" fmt -check -recursive -diff -no-color; then ok "$tf fmt"; else bad "$tf fmt -check (run: $tf fmt -recursive $TPL)"; fi

# A copy configured away from the defaults, in every way tofu reads variables.
cat >"$tmp/terraform.tfvars" <<'EOF'
distro          = "fedora"
provision       = false
instance_memory = "8GiB"
EOF
cat >"$tmp/local.auto.tfvars" <<'EOF'
instance_cpu      = "7"
instance_swap     = "off"
instance_profiles = ["other"]
EOF
configured=(TF_VAR_wait_network_seconds=0 TF_VAR_user_name=someone TF_VAR_instance_nesting=false)

# The lock file must already cover this platform: init may not change it. It
# holds OpenTofu's registry, so HashiCorp Terraform records its own (copy only).
lockfile=(-lockfile=readonly)
case "$("$TOFU" version)" in Terraform*) lockfile=() ;; esac
if "$TOFU" -chdir="$tmp" init -backend=false -input=false "${lockfile[@]}" -no-color >"$tmp/init.log" 2>&1; then
	ok "$tf init$([ ${#lockfile[@]} = 0 ] || echo ' with the committed lock file')"
	if "$TOFU" -chdir="$tmp" validate -no-color >"$tmp/validate.log" 2>&1; then
		ok "$tf validate"
	else
		bad "$tf validate:"
		cat "$tmp/validate.log" >&2
	fi
	if env "${configured[@]}" "$TOFU" -chdir="$tmp" test -no-color >"$tmp/test.log" 2>&1; then
		ok "$tf test, on a copy configured with tfvars and TF_VAR_*: $(tail -1 "$tmp/test.log")"
	else
		bad "$tf test (on a copy configured with tfvars and TF_VAR_*, which tests/terraform.tfvars must override):"
		grep -v '\.\.\. pass$' "$tmp/test.log" >&2
	fi
else
	bad "$tf init:"
	cat "$tmp/init.log" >&2
fi

if [ "$failed" = 0 ]; then echo "all checks passed"; else exit 1; fi
