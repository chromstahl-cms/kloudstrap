#!/bin/bash

rm -f .fdn

PLUGIN_DIR="extracted_plugins"
if [ ! -d $PLUGIN_DIR ]; then
    mkdir $PLUGIN_DIR
fi

CHANGED=false

for filename in plugins/*.tar.gz; do
    META=$(tar xfO $filename meta.json)
    AUTHOR=$(echo $META | jq -r '.author')
    NAME=$(echo $META | jq -r '.name')
    VERSION=$(echo $META | jq -r '.version')
    FULLY_QUALIFIED=$PLUGIN_DIR/$AUTHOR/$NAME/$VERSION
    echo $FULLY_QUALIFIED >> .fdn
    if [ ! -d $FULLY_QUALIFIED ]; then
        CHANGED=true
        echo "Found new Plugin $NAME from $AUTHOR in version $VERSION"
        mkdir -p $FULLY_QUALIFIED
        tar xvf $filename -C $FULLY_QUALIFIED &>/dev/null
    fi
done

function writeDockerFile {
    echo "ADD $1 frontend/$1" >> Dockerfile
}

function prepDocker {
    rm -f Dockerfile
    cat << EOF >> Dockerfile
FROM voidlinux/voidlinux
# Install java
RUN xbps-install -Syu wget nodejs git
RUN wget https://download.java.net/java/GA/jdk12/GPL/openjdk-12_linux-x64_bin.tar.gz -O /tmp/jdk.tar.gz && \
 mkdir -p /opt/jvm && \
 tar xfvz /tmp/jdk.tar.gz --directory /opt/jvm && \
 rm -f /tmp/openjdk-11+28_linux-x64_bin.tar.gz
ENV PATH="\$PATH:/opt/jvm/jdk-12/bin"

RUN git clone https://github.com/kloud-ms/frontend.git
EOF
}

if $CHANGED; then
    prepDocker
    while read path; do
        writeDockerFile $path
    done <.fdn
fi
