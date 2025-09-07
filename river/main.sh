#!/bin/bash
ENV=rserver-$tag
eval "$(micromamba shell hook --shell bash)" 
micromamba activate $ENV||micromamba create -n $ENV conda-forge::r-base=4.4.2 conda-forge::python=3.12 conda-forge::singularity=3.8.6 -y && micromamba activate $ENV
USER=$(whoami)
TMPDIR=${TMPDIR:-$RIVER_HOME/tmp}
CONTAINER="$RIVER_HOME/images/singularities/images/rstudio-4.4.2.sif"

# Set-up temporary paths
RSTUDIO_TMP="${TMPDIR}/$(echo -n $CONDA_PREFIX | md5sum | awk '{print $1}')"
mkdir -p $RSTUDIO_TMP/{run,var-lib-rstudio-server,local-share-rstudio}

R_BIN=$(which R)
PY_BIN=$(which python)

if [ ! -f $CONTAINER ]; then
        singularity pull $CONTAINER docker://docker.io/rocker/rstudio:4.4.2
fi

if [ -z "$CONDA_PREFIX" ]; then
  echo "Activate a conda env or specify \$CONDA_PREFIX"
  exit 1
fi

echo "Starting rstudio service on port $PORT ..."
# prepare database and session
rstudio_home=$RIVER_HOME/packages/rstudio 
rstudio_config=$rstudio_home/config
mkdir -p $rstudio_config

session=$rstudio_home/rsession.conf
db=$rstudio_home/database.conf

if [ ! -f $session ]; then
    cp ./analysis/river/rsession.conf $session
fi

if [ ! -f $db ]; then
    cp ./analysis/river/database.conf $db
fi

script -q -c "singularity run \
        --bind $RSTUDIO_TMP/run:/run \
        --bind $RSTUDIO_TMP/var-lib-rstudio-server:/var/lib/rstudio-server \
        --bind /sys/fs/cgroup/:/sys/fs/cgroup/:ro \
        --bind $db:/etc/rstudio/database.conf \
        --bind $session:/etc/rstudio/rsession.conf \
        --bind $RSTUDIO_TMP/local-share-rstudio:/home/rstudio/.local/share/rstudio \
        --bind $HOME:/home/rstudio \
        --env RSTUDIO_WHICH_R=$R_BIN \
        --env RETICULATE_PYTHON=$PY_BIN \
        $CONTAINER \
        rserver \
                --www-address=0.0.0.0 \
                --www-port=$PORT \
                --server-working-dir $HOME \
                --rsession-which-r=$R_BIN \
                --rsession-ld-library-path=$CONDA_PREFIX/lib \
        --auth-none=1 \
        --server-user $USER"