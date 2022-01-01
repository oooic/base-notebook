FROM python:3.10-buster as builder

WORKDIR /opt/app

COPY requirements.lock /opt/app
RUN pip3 install -r requirements.lock


# ここからは実行用コンテナの準備
FROM python:3.10-slim-buster as runner

COPY --from=builder /usr/local/lib/python3.10/site-packages /usr/local/lib/python3.10/site-packages
COPY --from=builder /usr/local/bin/jupyter /usr/local/bin/jupyter 
COPY --from=builder /usr/local/bin/jupyter-notebook /usr/local/bin/jupyter-notebook
COPY --from=builder /usr/local/bin/jupyter-lab /usr/local/bin/jupyter-lab
COPY --from=builder /usr/local/bin/jupyter-contrib /usr/local/bin/jupyter-contrib

ARG PY_USER="pyusr"
ARG PY_UID="1000"
ARG PY_GID="100"

RUN apt-get update --yes && \
    apt-get upgrade --yes && \
    apt-get install --yes --no-install-recommends \
    wget \
    ca-certificates \
    sudo \
    locales \
    tini \
    fonts-liberation &&\
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

# Configure environment
ENV SHELL=/bin/bash \
    PY_USER="${PY_USER}" \
    PY_UID=${PY_UID} \
    PY_GID=${PY_GID} \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8

ENV HOME="/home/${PY_USER}"
# Create PY_USER with name jovyan user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "auth requisite pam_deny.so" >> /etc/pam.d/su && \
    useradd -l -m -s /bin/bash -N -u "${PY_UID}" "${PY_USER}" && \
    chmod g+w /etc/passwd

USER ${PY_UID}

WORKDIR "${HOME}"
RUN jupyter-notebook --generate-config && \
    jupyter-lab clean

EXPOSE 8888

# Configure container startup
ENTRYPOINT ["tini", "-g", "--"]
CMD ["start-notebook.sh"]

# Copy local files as late as possible to avoid cache busting
COPY start.sh start-notebook.sh start-singleuser.sh /usr/local/bin/
# Currently need to have both jupyter_notebook_config and jupyter_server_config to support classic and lab
COPY jupyter_notebook_config.py /etc/jupyter/

# Fix permissions on /etc/jupyter as root
USER root

# Prepare upgrade to JupyterLab V3.0 #1205
RUN sed -re "s/c.NotebookApp/c.ServerApp/g" \
    /etc/jupyter/jupyter_notebook_config.py > /etc/jupyter/jupyter_server_config.py

# Switch back to jovyan to avoid accidental container runs as root
USER ${PY_UID}
