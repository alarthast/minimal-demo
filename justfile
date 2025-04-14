export VIRTUAL_ENV  := env_var_or_default("VIRTUAL_ENV", ".venv")

export BIN := VIRTUAL_ENV + if os_family() == "unix" { "/bin" } else { "/Scripts" }
export PIP := BIN + if os_family() == "unix" { "/python -m pip" } else { "/python.exe -m pip" }

export DEFAULT_PYTHON := if os_family() == "unix" { `cat .python-version` } else { "python" }


# list available commands
default:
    @"{{ just_executable() }}" --list


# clean up temporary files
clean:
    rm -rf .venv


# ensure valid virtualenv
virtualenv *args:
    #!/usr/bin/env bash
    set -euo pipefail

    # Allow users to specify python version in .env
    PYTHON_VERSION=${PYTHON_VERSION:-$DEFAULT_PYTHON}

    # Create venv; installs `uv`-managed python if python interpreter not found
    test -d $VIRTUAL_ENV || uv venv --python $PYTHON_VERSION {{ args }}

    # Block accidentally usage of system pip by placing an executable at .venv/bin/pip
    echo 'echo "pip is not installed: use uv pip for a pip-like interface."' > .venv/bin/pip
    chmod +x .venv/bin/pip

# Wrap `uv` commands that alter the lockfile
_uv +args: virtualenv
    #!/usr/bin/env bash
    set -euo pipefail

    LOCKFILE_TIMESTAMP=$(grep -n exclude-newer uv.lock | cut -d'=' -f2 | cut -d'"' -f2) || LOCKFILE_TIMESTAMP=""
    UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER:-$LOCKFILE_TIMESTAMP}

    if [ -n "${UV_EXCLUDE_NEWER}" ]; then
        # echo "Using uv with UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER}."
        export UV_EXCLUDE_NEWER
    else
        unset UV_EXCLUDE_NEWER
    fi

    uv {{ args }}

# update uv.lock if dependencies in pyproject.toml have changed
requirements-prod *args: (_uv "lock" args)

# update uv.lock if dependencies in pyproject.toml have changed
requirements-dev *args: (_uv "lock" args)

# ensure prod requirements installed and up to date
prodenv: requirements-prod (_uv "sync --frozen --no-dev")


# && dependencies are run after the recipe has run. Needs just>=0.9.9. This is
# a killer feature over Makefiles.
#
# ensure prod and dev requirements installed and up to date
devenv: requirements-dev (_uv "sync --frozen") && install-precommit


# ensure precommit is installed
install-precommit:
    #!/usr/bin/env bash
    set -euo pipefail

    BASE_DIR=$(git rev-parse --show-toplevel)
    test -f $BASE_DIR/.git/hooks/pre-commit || $BIN/pre-commit install


# upgrade dev and prod dependencies (specify package to upgrade single package, all by default)
upgrade env package="": virtualenv
    #!/usr/bin/env bash
    set -euo pipefail

    opts="--upgrade"
    test -z "{{ package }}" || opts="--upgrade-package {{ package }}"

    LOCKFILE_TIMESTAMP=$(grep -n exclude-newer uv.lock | cut -d'=' -f2 | cut -d'"' -f2) || LOCKFILE_TIMESTAMP=""
    if [ -z "${LOCKFILE_TIMESTAMP}" ]; then
        uv lock $opts
    else
        uv lock --exclude-newer $LOCKFILE_TIMESTAMP $opts
    fi

# Upgrade all dev and prod dependencies.
# This is the default input command to update-dependencies action
# https://github.com/bennettoxford/update-dependencies-action
update-dependencies date="": virtualenv
    #!/usr/bin/env bash
    set -euo pipefail

    LOCKFILE_TIMESTAMP=$(grep -n exclude-newer uv.lock | cut -d'=' -f2 | cut -d'"' -f2) || LOCKFILE_TIMESTAMP=""
    if [ -z "{{ date }}" ]; then
        UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER:-$LOCKFILE_TIMESTAMP}
    else
        UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER:-$(date -d "{{ date }}" +"%Y-%m-%dT%H:%M:%SZ")}
    fi

    if [ -n "${UV_EXCLUDE_NEWER}" ]; then
        if [ -n "${LOCKFILE_TIMESTAMP}" ]; then
            touch -d "$UV_EXCLUDE_NEWER" $VIRTUAL_ENV/.target
            touch -d "$LOCKFILE_TIMESTAMP" $VIRTUAL_ENV/.existing
            if [ $VIRTUAL_ENV/.existing -nt $VIRTUAL_ENV/.target ]; then
                echo "The lockfile timestamp is newer than the target cutoff. Using the lockfile timestamp."
                UV_EXCLUDE_NEWER=$LOCKFILE_TIMESTAMP
            fi
        fi
        echo "UV_EXCLUDE_NEWER set to $UV_EXCLUDE_NEWER."
        export UV_EXCLUDE_NEWER
    else
        echo "UV_EXCLUDE_NEWER not set."
        unset UV_EXCLUDE_NEWER
    fi

    uv lock --upgrade

# *args is variadic, 0 or more. This allows us to do `just test -k match`, for example.
# Run the tests
test *args: devenv
    $BIN/coverage run --module pytest {{ args }}
    $BIN/coverage report || $BIN/coverage html


format *args=".": devenv
    $BIN/ruff format --check {{ args }}

lint *args=".": devenv
    $BIN/ruff check {{ args }}

# run the various dev checks but does not change any files
check: format lint


# fix formatting and import sort ordering
fix: devenv
    $BIN/ruff check --fix .
    $BIN/ruff format .


# Run the dev project
run: devenv
    echo "Not implemented yet"



# Remove built assets and collected static files
assets-clean:
    rm -rf assets/dist
    rm -rf staticfiles


# Install the Node.js dependencies
assets-install:
    #!/usr/bin/env bash
    set -euo pipefail

    # exit if lock file has not changed since we installed them. -nt == "newer than",
    # but we negate with || to avoid error exit code
    test package-lock.json -nt node_modules/.written || exit 0

    npm ci
    touch node_modules/.written


# Build the Node.js assets
assets-build:
    #!/usr/bin/env bash
    set -euo pipefail

    # find files which are newer than dist/.written in the src directory. grep
    # will exit with 1 if there are no files in the result.  We negate this
    # with || to avoid error exit code
    # we wrap the find in an if in case dist/.written is missing so we don't
    # trigger a failure prematurely
    if test -f assets/dist/.written; then
        find assets/src -type f -newer assets/dist/.written | grep -q . || exit 0
    fi

    npm run build
    touch assets/dist/.written


assets: assets-install assets-build


assets-rebuild: assets-clean assets
