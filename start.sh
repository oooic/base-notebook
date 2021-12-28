#!/bin/bash
# Copyright (c) Jupyter Development Team.
# Distributed under the terms of the Modified BSD License.

set -e

# The _log function is used for everything this script wants to log. It will
# always log errors and warnings, but can be silenced for other messages
# by setting JUPYTER_DOCKER_STACKS_QUIET environment variable.
_log () {
    if [[ "$*" == "ERROR:"* ]] || [[ "$*" == "WARNING:"* ]] || [[ "${JUPYTER_DOCKER_STACKS_QUIET}" == "" ]]; then
        echo "$@"
    fi
}
_log "Entered start.sh with args:" "$@"

# The run-hooks function looks for .sh scripts to source and executable files to
# run within a passed directory.
run-hooks () {
    if [[ ! -d "${1}" ]] ; then
        return
    fi
    _log "${0}: running hooks in ${1} as uid / gid: $(id -u) / $(id -g)"
    for f in "${1}/"*; do
        case "${f}" in
            *.sh)
                _log "${0}: running script ${f}"
                # shellcheck disable=SC1090
                source "${f}"
                ;;
            *)
                if [[ -x "${f}" ]] ; then
                    _log "${0}: running executable ${f}"
                    "${f}"
                else
                    _log "${0}: ignoring non-executable ${f}"
                fi
                ;;
        esac
    done
    _log "${0}: done running hooks in ${1}"
}

# A helper function to unset env vars listed in the value of the env var
# JUPYTER_ENV_VARS_TO_UNSET.
unset_explicit_env_vars () {
    if [ -n "${JUPYTER_ENV_VARS_TO_UNSET}" ]; then
        for env_var_to_unset in $(echo "${JUPYTER_ENV_VARS_TO_UNSET}" | tr ',' ' '); do
            echo "Unset ${env_var_to_unset} due to JUPYTER_ENV_VARS_TO_UNSET"
            unset "${env_var_to_unset}"
        done
        unset JUPYTER_ENV_VARS_TO_UNSET
    fi
}


# Default to starting bash if no command was specified
if [ $# -eq 0 ]; then
    cmd=( "bash" )
else
    cmd=( "$@" )
fi

# NOTE: This hook will run as the user the container was started with!
run-hooks /usr/local/bin/start-notebook.d

# If the container started as the root user, then we have permission to refit
# the pyusr user, and ensure file permissions, grant sudo rights, and such
# things before we run the command passed to start.sh as the desired user
# (NB_USER).
#
if [ "$(id -u)" == 0 ] ; then
    # Environment variables:
    # - NB_USER: the desired username and associated home folder
    # - NB_UID: the desired user id
    # - NB_GID: a group id we want our user to belong to
    # - NB_GROUP: the groupname we want for the group
    # - GRANT_SUDO: a boolean ("1" or "yes") to grant the user sudo rights
    # - CHOWN_HOME: a boolean ("1" or "yes") to chown the user's home folder
    # - CHOWN_EXTRA: a comma separated list of paths to chown
    # - CHOWN_HOME_OPTS / CHOWN_EXTRA_OPTS: arguments to the chown commands

    # Refit the pyusr user to the desired the user (NB_USER)
    if id pyusr &> /dev/null ; then
        if ! usermod --home "/home/${PY_USER}" --login "${PY_USER}" pyusr 2>&1 | grep "no changes" > /dev/null; then
            _log "Updated the pyusr user:"
            _log "- username: pyusr       -> ${PY_USER}"
            _log "- home dir: /home/pyusr -> /home/${PY_USER}"
        fi
    elif ! id -u "${PY_USER}" &> /dev/null; then
        _log "ERROR: Neither the pyusr user or '${PY_USER}' exists. This could be the result of stopping and starting, the container with a different NB_USER environment variable."
        exit 1
    fi
    # Ensure the desired user (NB_USER) gets its desired user id (NB_UID) and is
    # a member of the desired group (NB_GROUP, NB_GID)
    if [ "${PY_UID}" != "$(id -u "${PY_USER}")" ] || [ "${PY_GID}" != "$(id -g "${PY_USER}")" ]; then
        _log "Update ${PY_USER}'s UID:GID to ${PY_UID}:${PY_GID}"
        # Ensure the desired group's existence
        if [ "${PY_GID}" != "$(id -g "${PY_USER}")" ]; then
            groupadd --force --gid "${PY_GID}" --non-unique "${PY_GROUP:-${PY_USER}}"
        fi
        # Recreate the desired user as we want it
        userdel "${PY_USER}"
        useradd --home "/home/${PY_USER}" --uid "${PY_UID}" --gid "${PY_GID}" --groups 100 --no-log-init "${PY_USER}"
    fi

    # Move or symlink the pyusr home directory to the desired users home
    # directory if it doesn't already exist, and update the current working
    # directory to the new location if needed.
    if [[ "${PY_USER}" != "pyusr" ]]; then
        if [[ ! -e "/home/${PY_USER}" ]]; then
            _log "Attempting to copy /home/pyusr to /home/${PY_USER}..."
            mkdir "/home/${PY_USER}"
            if cp -a /home/pyusr/. "/home/${PY_USER}/"; then
                _log "Success!"
            else
                _log "Failed to copy data from /home/pyusr to /home/${PY_USER}!"
                _log "Attempting to symlink /home/pyusr to /home/${PY_USER}..."
                if ln -s /home/pyusr "/home/${PY_USER}"; then
                    _log "Success creating symlink!"
                else
                    _log "ERROR: Failed copy data from /home/pyusr to /home/${PY_USER} or to create symlink!"
                    exit 1
                fi
            fi
        fi
        # Ensure the current working directory is updated to the new path
        if [[ "${PWD}/" == "/home/pyusr/"* ]]; then
            new_wd="/home/${PY_USER}/${PWD:13}"
            _log "Changing working directory to ${new_wd}"
            cd "${new_wd}"
        fi
    fi

    # Optionally ensure the desired user get filesystem ownership of it's home
    # folder and/or additional folders
    if [[ "${CHOWN_HOME}" == "1" || "${CHOWN_HOME}" == "yes" ]]; then
        _log "Ensuring /home/${PY_USER} is owned by ${PY_UID}:${PY_GID} ${CHOWN_HOME_OPTS:+(chown options: ${CHOWN_HOME_OPTS})}"
        # shellcheck disable=SC2086
        chown ${CHOWN_HOME_OPTS} "${PY_UID}:${PY_GID}" "/home/${PY_USER}"
    fi
    if [ -n "${CHOWN_EXTRA}" ]; then
        for extra_dir in $(echo "${CHOWN_EXTRA}" | tr ',' ' '); do
            _log "Ensuring ${extra_dir} is owned by ${PY_UID}:${PY_GID} ${CHOWN_EXTRA_OPTS:+(chown options: ${CHOWN_EXTRA_OPTS})}"
            # shellcheck disable=SC2086
            chown ${CHOWN_EXTRA_OPTS} "${PY_UID}:${PY_GID}" "${extra_dir}"
        done
    fi

    # Update potentially outdated environment variables since image build
    export XDG_CACHE_HOME="/home/${PY_USER}/.cache"

    # Add ${CONDA_DIR}/bin to sudo secure_path
    sed -r "s#Defaults\s+secure_path\s*=\s*\"?([^\"]+)\"?#Defaults secure_path=\"\1:${CONDA_DIR}/bin\"#" /etc/sudoers | grep secure_path > /etc/sudoers.d/path

    # Optionally grant passwordless sudo rights for the desired user
    if [[ "$GRANT_SUDO" == "1" || "$GRANT_SUDO" == "yes" ]]; then
        _log "Granting ${PY_USER} passwordless sudo rights!"
        echo "${PY_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/added-by-start-script
    fi

    # NOTE: This hook is run as the root user!
    run-hooks /usr/local/bin/before-notebook.d

    unset_explicit_env_vars
    _log "Running as ${PY_USER}:" "${cmd[@]}"
    exec sudo --preserve-env --set-home --user "${PY_USER}" \
        PATH="${PATH}" \
        PYTHONPATH="${PYTHONPATH:-}" \
        "${cmd[@]}"

# The container didn't start as the root user, so we will have to act as the
# user we started as.
else
    # Warn about misconfiguration of: granting sudo rights
    if [[ "${GRANT_SUDO}" == "1" || "${GRANT_SUDO}" == "yes" ]]; then
        _log "WARNING: container must be started as root to grant sudo permissions!"
    fi

    pyusr_UID="$(id -u pyusr 2>/dev/null)"  # The default UID for the pyusr user
    pyusr_GID="$(id -g pyusr 2>/dev/null)"  # The default GID for the pyusr user

    # Attempt to ensure the user uid we currently run as has a named entry in
    # the /etc/passwd file, as it avoids software crashing on hard assumptions
    # on such entry. Writing to the /etc/passwd was allowed for the root group
    # from the Dockerfile during build.
    #
    # ref: https://github.com/jupyter/docker-stacks/issues/552
    if ! whoami &> /dev/null; then
        _log "There is no entry in /etc/passwd for our UID=$(id -u). Attempting to fix..."
        if [[ -w /etc/passwd ]]; then
            _log "Renaming old pyusr user to nayvoj ($(id -u pyusr):$(id -g pyusr))"

            # We cannot use "sed --in-place" since sed tries to create a temp file in
            # /etc/ and we may not have write access. Apply sed on our own temp file:
            sed --expression="s/^pyusr:/nayvoj:/" /etc/passwd > /tmp/passwd
            echo "${PY_USER}:x:$(id -u):$(id -g):,,,:/home/pyusr:/bin/bash" >> /tmp/passwd
            cat /tmp/passwd > /etc/passwd
            rm /tmp/passwd

            _log "Added new ${PY_USER} user ($(id -u):$(id -g)). Fixed UID!"

            if [[ "${PY_USER}" != "pyusr" ]]; then
                _log "WARNING: user is ${PY_USER} but home is /home/pyusr. You must run as root to rename the home directory!"
            fi
        else
            _log "WARNING: unable to fix missing /etc/passwd entry because we don't have write permission. Try setting gid=0 with \"--user=$(id -u):0\"."
        fi
    fi

    # Warn about misconfiguration of: desired username, user id, or group id.
    # A misconfiguration occurs when the user modifies the default values of
    # NB_USER, NB_UID, or NB_GID, but we cannot update those values because we
    # are not root.
    if [[ "${PY_USER}" != "pyusr" && "${PY_USER}" != "$(id -un)" ]]; then
        _log "WARNING: container must be started as root to change the desired user's name with NB_USER=\"${PY_USER}\"!"
    fi
    if [[ "${PY_UID}" != "${pyusr_UID}" && "${PY_UID}" != "$(id -u)" ]]; then
        _log "WARNING: container must be started as root to change the desired user's id with NB_UID=\"${PY_UID}\"!"
    fi
    if [[ "${PY_GID}" != "${pyusr_GID}" && "${PY_GID}" != "$(id -g)" ]]; then
        _log "WARNING: container must be started as root to change the desired user's group id with NB_GID=\"${PY_GID}\"!"
    fi

    # Warn if the user isn't able to write files to ${HOME}
    if [[ ! -w /home/pyusr ]]; then
        _log "WARNING: no write access to /home/pyusr. Try starting the container with group 'users' (100), e.g. using \"--group-add=users\"."
    fi

    # NOTE: This hook is run as the user we started the container as!
    run-hooks /usr/local/bin/before-notebook.d
    unset_explicit_env_vars
    _log "Executing the command:" "${cmd[@]}"
    exec "${cmd[@]}"
fi
