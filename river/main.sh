#!/bin/bash
USER=$(whoami)
TMPDIR=${TMPDIR:-$RIVER_HOME/tmp}
CONTAINER="rstudio-4.4.2.sif"

cd analysis/river
# Set-up temporary paths
RSTUDIO_WORKSPACE="./workspace"
mkdir -p $RSTUDIO_WORKSPACE/{run,var-lib-rstudio-server,local-share-rstudio}

eval "$(pixi shell-hook)"

R_BIN=$(which R)
PY_BIN=$(which python)

if [ ! -f $CONTAINER ]; then
        singularity pull $CONTAINER docker://docker.io/rocker/rstudio:4.4.2
fi

echo "Using R binary: $R_BIN"
echo "Using Python binary: $PY_BIN"
echo "Starting rstudio service on port $PORT ..."
# prepare database and session
RSTUDIO_HOME=$RSTUDIO_WORKSPACE/packages/rstudio 
RSTUDIO_CONFIG=$RSTUDIO_WORKSPACE/config
mkdir -p $RSTUDIO_CONFIG

script -q -c "singularity run \
        --bind $RSTUDIO_WORKSPACE/run:/run \
        --bind $RSTUDIO_WORKSPACE/var-lib-rstudio-server:/var/lib/rstudio-server \
        --bind /sys/fs/cgroup/:/sys/fs/cgroup/:ro \
        --bind ./database.conf:/etc/rstudio/database.conf \
        --bind ./rsession.conf:/etc/rstudio/rsession.conf \
        --bind $RSTUDIO_WORKSPACE/local-share-rstudio:/home/rstudio/.local/share/rstudio \
        --bind $HOME:/home/rstudio \
        --env RSTUDIO_WHICH_R=$R_BIN \
        --env RETICULATE_PYTHON=$PY_BIN \
        ./$CONTAINER \
        rserver \
                --www-address=0.0.0.0 \
                --www-port=$PORT \
                --server-working-dir $HOME \
                --rsession-which-r=$R_BIN \
                --rsession-ld-library-path=$CONDA_PREFIX/lib \
        --auth-none=1 \
        --server-user $USER"